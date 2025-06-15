# FetchResultsPublisher
A simple class for observing CoreData fetch requests using Combine.
This class utilizes a [NSFetchedResultsController](https://developer.apple.com/documentation/coredata/nsfetchedresultscontroller) behind the scenes and only fetches results while there is at least one subscriber.

## Usage
1. Create an instance of an `NSFetchRequest`, assign at least one sort descriptor to it.
2. Create an instance of a `FetchResultsPublisher` publisher (optionally, keep a reference to this to manually trigger refreshes later)
3. Consume output like any other Combine publisher
   
```swift
let fetchRequest = MyManagedObject.fetchRequest()
fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \MyManagedObject.someKey, ascending: true)] // Sort by at least one descriptor

let publisher = FetchResultsPublisher(request: fetchRequest,
                                      context: CoreDataStack.desiredContext,
                                      cacheName: "MyManagedObjectCache-if_desired")
self.fetchResultsPublisher = publisher
self.fetchResultsCancellable = publisher
    .replaceError(with: [])
    .receive(on: RunLoop.main)
    .sink(receiveValue: { [weak self] groups in
        // Update published properties on `@Observable`, etc.
    })
```

## License
[MIT License](https://spdx.org/licenses/MIT.html)
