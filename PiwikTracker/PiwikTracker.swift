import Foundation

/// The Piwik Tracker is a Swift framework to send analytics to the Piwik server.
///
/// ## Basic Usage
/// * Configure the shared instance as early as possible in your application lifecyle.
/// * Use the track methods to track your views, events and more.
final public class PiwikTracker: NSObject {
    
    /// Defines if the user opted out of tracking. When set to true, every event
    /// will be discarded immediately. This property is persisted between app launches.
    public var isOptedOut: Bool {
        get {
            return piwikUserDefaults.optOut
        }
        set {
            piwikUserDefaults.optOut = newValue
        }
    }
    
    internal var piwikUserDefaults: PiwikUserDefaults
    private let dispatcher: Dispatcher
    private var queue: Queue
    internal let siteId: String

    internal var dimensions: [CustomDimension] = []
    
    
    /// This logger is used to perform logging of all sorts of piwik related information.
    /// Per default it is a `DefaultLogger` with a `minLevel` of `LogLevel.warning`. You can
    /// set your own Logger with a custom `minLevel` or a complete custom logging mechanism.
    public var logger: Logger = DefaultLogger(minLevel: .warning)
    
    internal static var _sharedInstance: PiwikTracker?
    
    /// Create and Configure a new Tracker
    ///
    /// - Parameters:
    ///   - siteId: The unique site id generated by the server when a new site was created.
    ///   - queue: The queue to use to store all analytics until it is dispatched to the server.
    ///   - dispatcher: The dispatcher to use to transmit all analytics to the server.
    required public init(siteId: String, queue: Queue, dispatcher: Dispatcher, suiteName: String? = nil) {
        self.siteId = siteId
        self.queue = queue
        self.dispatcher = dispatcher
        self.piwikUserDefaults = PiwikUserDefaults(suiteName: suiteName)
        self.visitor = Visitor.current(in: piwikUserDefaults)
        self.session = Session.current(in: piwikUserDefaults)
        super.init()
        startNewSession()
        startDispatchTimer()
    }
    
    /// Create and Configure a new Tracker
    ///
    /// A volatile memory queue will be used to store the analytics data. All not transmitted data will be lost when the application gets terminated.
    /// The URLSessionDispatcher will be used to transmit the data to the server.
    ///
    /// - Parameters:
    ///   - siteId: The unique site id generated by the server when a new site was created.
    ///   - baseURL: The url of the piwik server. This url has to end in `piwik.php`.
    convenience public init(siteId: String, baseURL: URL) {
        let queue = MemoryQueue()
        let dispatcher = URLSessionDispatcher(baseURL: baseURL)
        self.init(siteId: siteId, queue: queue, dispatcher: dispatcher)
    }
    
    internal func queue(event: Event) {
        guard !isOptedOut else { return }
        logger.verbose("Queued event: \(event)")
        queue.enqueue(event: event)
        nextEventStartsANewSession = false
    }
    
    // MARK: dispatching
    
    private let numberOfEventsDispatchedAtOnce = 20
    private(set) var isDispatching = false
    
    
    /// Manually start the dispatching process. You might want to call this method in AppDelegates `applicationDidEnterBackground` to transmit all data
    /// whenever the user leaves the application.
    public func dispatch() {
        guard !isDispatching else {
            logger.verbose("PiwikTracker is already dispatching.")
            return
        }
        guard queue.eventCount > 0 else {
            logger.info("No need to dispatch. Dispatch queue is empty.")
            startDispatchTimer()
            return
        }
        logger.info("Start dispatching events")
        isDispatching = true
        dispatchBatch()
    }
    
    private func dispatchBatch() {
        queue.first(limit: numberOfEventsDispatchedAtOnce) { events in
            guard events.count > 0 else {
                // there are no more events queued, finish dispatching
                self.isDispatching = false
                self.logger.info("Finished dispatching events")
                return
            }
            self.dispatcher.send(events: events, success: {
                self.queue.remove(events: events, completion: {
                    self.logger.info("Dispatched batch of \(events.count) events.")
                    self.dispatchBatch()
                })
            }, failure: { shouldContinue in
                self.logger.warning("Failed dispatching events with error \(shouldContinue)")
                self.isDispatching = false
            })
        }
    }
    
    // MARK: dispatch timer
    
    private let dispatchInterval: TimeInterval = 30.0 // Discussion: move this into a configuration?
    private var dispatchTimer: Timer?
    
    private func startDispatchTimer() {
        guard dispatchInterval > 0  else { return } // Discussion: Do we want the possibility to dispatch synchronous? That than would be dispatchInterval = 0
        if let dispatchTimer = dispatchTimer {
            dispatchTimer.invalidate()
            self.dispatchTimer = nil
        }
        self.dispatchTimer = Timer.scheduledTimer(timeInterval: dispatchInterval, target: self, selector: #selector(dispatch), userInfo: nil, repeats: false)
    }
    
    internal var visitor: Visitor
    internal var session: Session
    internal var nextEventStartsANewSession = true
}

extension PiwikTracker {
    /// Starts a new Session
    ///
    /// Use this function to manually start a new Session. A new Session will be automatically created only on app start.
    /// You can use the AppDelegates `applicationWillEnterForeground` to start a new visit whenever the app enters foreground.
    public func startNewSession() {
        piwikUserDefaults.previousVisit = piwikUserDefaults.currentVisit
        piwikUserDefaults.currentVisit = Date()
        piwikUserDefaults.totalNumberOfVisits += 1
        self.session = Session.current(in: piwikUserDefaults)
    }
}

// shared instance
extension PiwikTracker {
    
    /// Returns the shared tracker. Will return nil if the tracker was not properly confured before.
    public static var shared: PiwikTracker? {
        get { return _sharedInstance }
    }
    
    /// Configures the shared instance.
    ///
    /// A volatile memory queue will be used to store the analytics data. All not transmitted data will be lost when the application gets terminated.
    /// The URLSessionDispatcher will be used to transmit the data to the server.
    ///
    /// - Parameters:
    ///   - siteId: The unique site id generated by the server when a new site was created.
    ///   - baseURL: The url of the piwik server. This url has to end in `piwik.php`.
    public class func configureSharedInstance(withSiteID siteID: String, baseURL: URL) {
        let queue = MemoryQueue()
        let dispatcher = URLSessionDispatcher(baseURL: baseURL)
        self._sharedInstance = PiwikTracker.init(siteId: siteID, queue: queue, dispatcher: dispatcher)
    }
    
    /// Configures the shared instance.
    ///
    /// - Parameters:
    /// - Parameters:
    ///   - siteId: The unique site id generated by the server when a new site was created.
    ///   - queue: The queue to use to store all analytics until it is dispatched to the server.
    ///   - dispatcher: The dispatcher to use to transmit all analytics to the server.
    public class func configureSharedInstance(withSiteID siteID: String, queue: Queue = MemoryQueue(), dispatcher: Dispatcher) {
        self._sharedInstance = PiwikTracker(siteId: siteID, queue: queue, dispatcher: dispatcher)
    }
}

extension PiwikTracker {
    internal func event(action: [String], url: URL? = nil) -> Event {
        let url = url ?? URL(string: "http://example.com")!.appendingPathComponent(action.joined(separator: "/"))
        return Event(
            siteId: siteId,
            uuid: NSUUID(),
            visitor: visitor,
            session: session,
            date: Date(),
            url: url,
            actionName: action,
            language: Locale.httpAcceptLanguage,
            isNewSession: nextEventStartsANewSession,
            referer: nil,
            eventCategory: nil,
            eventAction: nil,
            eventName: nil,
            eventValue: nil,
            dimensions: dimensions
        )
    }
    internal func event(withCategory category: String, action: String, name: String? = nil, value: Float? = nil) -> Event {
        return Event(
            siteId: siteId,
            uuid: NSUUID(),
            visitor: visitor,
            session: session,
            date: Date(),
            url: URL(string: "http://example.com")!,
            actionName: [],
            language: Locale.httpAcceptLanguage,
            isNewSession: nextEventStartsANewSession,
            referer: nil,
            eventCategory: category,
            eventAction: action,
            eventName: name,
            eventValue: value,
            dimensions: dimensions
        )
    }
}

extension PiwikTracker {
    /// Tracks a screenview.
    ///
    /// This method can be used to track hierarchical screen names, e.g. screen/settings/register. Use this to create a hierarchical and logical grouping of screen views in the Piwik web interface.
    ///
    /// - Parameter view: An array of hierarchical screen names.
    /// - Parameter url: The url of the page that was viewed. If none set the url will be http://example.com appended by the screen segments. Example: http://example.com/players/john-appleseed
    public func track(view: [String], url: URL? = nil) {
        queue(event: event(action: view, url: url))
    }
    
    /// Tracks an event as described here: https://piwik.org/docs/event-tracking/
    public func track(eventWithCategory category: String, action: String, name: String? = nil, value: Float? = nil) {
        queue(event: event(withCategory: category, action: action, name: name, value: value))
    }
}

extension PiwikTracker {
    /// Set a permanent custom dimension.
    ///
    /// Use this method to set a dimension that will be send with every event. This is best for Custom Dimensions in scope "Visit". A typical example could be any device information or the version of the app the visitor is using.
    ///
    /// For more information on custom dimensions visit https://piwik.org/docs/custom-dimensions/
    ///
    /// - Parameter value: The value you want to set for this dimension.
    /// - Parameter index: The index of the dimension. A dimension with this index must be setup in the piwik backend.
    public func set(value: String, forIndex index: Int) {
        let dimension = CustomDimension(index: index, value: value)
        remove(dimensionAtIndex: dimension.index)
        dimensions.append(dimension)
    }
    
    /// Removes a previously set custom dimension.
    ///
    /// Use this method to remove a dimension that was set using the `set(value: String, forDimension index: Int)` method.
    ///
    /// - Parameter index: The index of the dimension.
    public func remove(dimensionAtIndex index: Int) {
        dimensions = dimensions.filter({ dimension in
            dimension.index != index
        })
    }
}

// Objective-c compatibility extension
extension PiwikTracker {
    
    @objc public func track(eventWithCategory category: String, action: String, name: String? = nil, number: NSNumber? = nil) {
        let value = number == nil ? nil : number!.floatValue
        track(eventWithCategory: category, action: action, name: name, value: value)
    }
}
