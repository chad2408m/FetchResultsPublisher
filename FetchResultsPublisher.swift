//
//  FetchResultsPublisher.swift
//  FetchResultsPublisher
//
//  Created by Chad Meyers on 9/1/24.
//
//  MIT License
//
//  Copyright (c) 2024 Chad Meyers
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Combine
import CoreData
import Foundation
import OSLog

/// A publisher which publishes `NSManagedObject`s which match a certain predicate, subscribing to live updates of the query.
public typealias FetchResultsPublisher<T: NSFetchRequestResult> = Publishers.FetchResults<T>

/// A logger to use for debug purposes
fileprivate let FetchResultLogger: Logger = Logger(subsystem: "com.fetchresultpublisher", category: "FetchResultPublisher")

/// A signpost to use for performance tracking
fileprivate let FetchResultSignpost: OSSignposter = OSSignposter(logger: FetchResultLogger)

extension Publishers {
    /// A publisher which publishes `NSManagedObject`s which match a certain predicate, subscribing to live updates of the query.
    /// The publisher utilizes a `NSFetchedResultsController` as it's backing implementation, and therefore many of the nuances and configuration for that type applies here as well.
    public struct FetchResults<T>: Publisher where T: NSFetchRequestResult {
        public typealias Output = [T]
        public typealias Failure = Error
        
        private let coordinator: Coordinator
        
        /// Creates a new instance of a fetch result publisher.
        ///
        /// Each instance will monitor the fetch request independently, so it is more performant to utilize a single publisher with multiple subscribers than to create multiple identical publishers.
        ///
        /// - Parameters:
        ///   - request: The `NSFetchRequest` which is used to filter and sort the returned objects
        ///   - context: The managed object context the `request` is executed with
        ///   - cacheName: An optional cache to use for the request results, making future fetches nearly-instantaneous. See `NSFetchedResultsController` for more details.
        public init(request: NSFetchRequest<T>, context: NSManagedObjectContext, cacheName: String? = nil) {
            self.coordinator = Coordinator(request: request, context: context, cacheName: cacheName)
        }
        
        /// May be invoked to force this publisher to perform the fetch request immediately again, notifying all observers of the results.
        public func refreshResultsImmediately() {
            self.coordinator.performFetchImmediately()
        }
        
        public func receive<S>(subscriber: S) where S : Subscriber, any Failure == S.Failure, [T] == S.Input {
            subscriber.receive(subscription: Subscription(subscriber: subscriber, coordinator: coordinator))
        }
    }
}

//MARK: Handling updates

extension Publishers.FetchResults {
    /// A representation of a single subscription to a ``FetchResults`` publisher.
    ///
    /// The subscription is used to keep the ``Coordinator`` retained in memory.
    /// The lifespan of a coordinator is only for as long as there is at least one subscription.
    ///
    /// Coordinators keep a reference active subscriptions, and notify them when fetched results have changed.
    fileprivate final class Subscription: Combine.Subscription {
        /// The object which has subscribed to receive updates and is the owner of this subscription
        private var subscriber: (any Subscriber<[T], Error>)?
        
        /// A strong reference retaining the coordinator of this subscription.
        ///
        /// Always non-nil until the subscriber cancels it's subscription, and after cancelling the subscription may not be re-used.
        private var coordinator: Coordinator?
        
        /// The current demand for results.
        ///
        /// When demand is `.unlimited`, this subscription will subscribe to live updates from the the publisher.
        /// When demand is exactly `1`, only a single fetch result will be returned.
        private var demand: Subscribers.Demand = .none
        
        /// Creates a new subscription between the specified subscriber and coordinator
        init<S>(subscriber: S, coordinator: Coordinator) where S: Subscriber, S.Input == [T], S.Failure == Error {
            self.subscriber = subscriber
            self.coordinator = coordinator
        }
        
        func request(_ demand: Subscribers.Demand) {
            self.demand += demand
            
            if let coordinator = self.coordinator {
                if self.demand > 0 {
                    coordinator.beginObserving(subscription: self)
                } else {
                    coordinator.endObserving(subscription: self)
                }
                
                coordinator.performFetchIfNeeded(requestor: self)
            }
        }
        
        /// Invoked when new results are available from the ``Coordinator``.
        func onUpdate(results: [T]) {
            guard let subscriber = self.subscriber,
                  let coordinator = self.coordinator,
                  self.demand > 0 else {
                return
            }
            
            // Send the result to the subscriber
            let updatedDemand = subscriber.receive(results)
            
            // Only update demand if we hadn't previously requested unlimited results
            if self.demand != .unlimited {
                self.demand = updatedDemand
                
                if self.demand <= 0 {
                    coordinator.endObserving(subscription: self)
                }
            }
        }
        
        /// Invoked when an unrecoverable error occurred within the ``Coordinator``.
        /// The subscription is terminated.
        func onError(_ error: Error) {
            guard let subscriber = self.subscriber,
                  let coordinator = self.coordinator,
                  self.demand > 0 else {
                return
            }
            
            self.demand = .none
            subscriber.receive(completion: .failure(error))
            coordinator.endObserving(subscription: self)
        }
        
        func cancel() {
            self.coordinator?.endObserving(subscription: self)
            self.demand = .none
            self.subscriber = nil
            self.coordinator = nil // Release our reference to the coordinator - it may be deallocated now
        }
    }
    
    /// The primary driver of a ``FetchResults`` publisher, the Coordinator is responsible for creating an `NSFetchedResultsController` and executing fetch requests.
    ///
    /// A Coordinator also manages a list of ``Subscription``s which are active and requesting to be updated when there are changes in the fetched objects.
    fileprivate final class Coordinator: NSObject, NSFetchedResultsControllerDelegate {
        private let fetchResultsController: NSFetchedResultsController<T>
        private var fetchStatus: FetchStatus = .notFetched
        private var activeSubscriptions: [() -> Subscription?] = []
        
        init(request: NSFetchRequest<T>, context: NSManagedObjectContext, cacheName: String? = nil) {
            if request.sortDescriptors == nil || request.sortDescriptors!.isEmpty {
                FetchResultLogger.critical("Fetch request created with no sort descriptor. Behavior is undefined.")
            }
            
            self.fetchResultsController = NSFetchedResultsController(fetchRequest: request,
                                                                     managedObjectContext: context,
                                                                     sectionNameKeyPath: nil,
                                                                     cacheName: cacheName)
            super.init()
            self.fetchResultsController.delegate = self
        }
        
        func beginObserving(subscription: Subscription) {
            if !self.activeSubscriptions.contains(where: { $0() === subscription }) {
                self.activeSubscriptions.append { [weak subscription] in return subscription }
            }
        }
        
        func endObserving(subscription: Subscription) {
            self.activeSubscriptions.removeAll { capturedSubscription in
                let activeSubscription = capturedSubscription()
                
                return activeSubscription == nil || activeSubscription === subscription
            }
        }
        
        func performFetchIfNeeded(requestor: Subscription) {
            switch self.fetchStatus {
            case .fetched:
                // Immediately return existing values if we've already successfully fetched
                requestor.onUpdate(results: self.fetchResultsController.fetchedObjects ?? [])
            case .inProgress:
                // Wait for ongoing fetch
                break
            case .notFetched:
                // Fetch now!
                self.performFetchImmediately()
            }
        }
        
        func performFetchImmediately() {
            FetchResultLogger.info("Will begin fetching results for `\(T.self)`")
            let fetchState = FetchResultSignpost.beginInterval("Fetching results")
            self.fetchStatus = .inProgress
            
            do {
                try self.fetchResultsController.performFetch()
                self.fetchStatus = .fetched
                FetchResultSignpost.endInterval("Fetching results", fetchState)
                FetchResultLogger.info("Did finish fetching results for `\(T.self)`")
                
                self.notify(results: self.fetchResultsController.fetchedObjects ?? [])
            } catch {
                self.fetchStatus = .notFetched
                FetchResultSignpost.endInterval("Fetching results", fetchState)
                FetchResultLogger.error("Did fail to fetch results for `\(T.self)`. Reason: \(error)")
                
                self.notify(error: error)
            }
        }
        
        func notify(results: [T]) {
            self.activeSubscriptions
                .compactMap { $0() }
                .forEach { subscription in
                    subscription.onUpdate(results: results)
                }
        }
        
        func notify(error: Error) {
            self.activeSubscriptions
                .compactMap { $0() }
                .forEach { subscription in
                    subscription.onError(error)
                }
        }
        
        func controllerDidChangeContent(_ controller: NSFetchedResultsController<any NSFetchRequestResult>) {
            guard let fetchedObjects = self.fetchResultsController.fetchedObjects else {
                return // Do not notify, we haven't succeeded in obtaining any results yet.
            }
            
            FetchResultLogger.info("Did receive updated results for `\(T.self)`")
            self.notify(results: fetchedObjects)
        }
    }
}

extension Publishers.FetchResults.Coordinator {
    /// The current status of the `NSFetchResultsController`
    fileprivate enum FetchStatus {
        /// The controller has not been requested for a fetch yet, or the previous one has failed.
        case notFetched
        
        /// The controller is currently fetching results
        case inProgress
        
        /// The controller has completed it's first fetch and has results available.
        case fetched
    }
}
