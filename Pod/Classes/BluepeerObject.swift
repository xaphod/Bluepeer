//
//  BluepeerObject.swift
//
//  Created by Tim Carr on 7/7/16.
//  Copyright © 2016 Tim Carr Photo. All rights reserved.
//

import Foundation
import CoreBluetooth
import CFNetwork
import CocoaAsyncSocket
import HHServices

// NOTE: requires pod CocoaAsyncSocket

@objc public enum RoleType: Int, CustomStringConvertible {
    case unknown = 0
    case server = 1
    case client = 2
    case all = 3
    
    public var description: String {
        switch self {
        case .server: return "Server"
        case .client: return "Client"
        case .unknown: return "Unknown"
        case .all: return "All"
        }
    }
    
    public static func roleFromString(_ roleStr: String?) -> RoleType {
        guard let roleStr = roleStr else {
            return .unknown
        }
        switch roleStr {
            case "Server": return .server
            case "Client": return .client
            case "Unknown": return .unknown
            case "All": return .all
        default: return .unknown
        }
    }
}

@objc public enum BluetoothState: Int {
    case unknown = 0
    case poweredOff = 1
    case poweredOn = 2
    case other = 3
}


@objc public enum BPPeerState: Int, CustomStringConvertible {
    case notConnected = 0
    case connecting = 1
    case awaitingAuth = 2
    case connected = 3
    
    public var description: String {
        switch self {
        case .notConnected: return "NotConnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .awaitingAuth: return "AwaitingAuth"
        }
    }
}

@objc open class BPPeer: NSObject {
    open var displayName: String = ""
    open var socket: GCDAsyncSocket?
    open var role: RoleType = .unknown
    open var state: BPPeerState = .notConnected
    open var IP: String = ""
    override open func isEqual(_ object: Any?) -> Bool {
        if let rhs = object as? BPPeer {
            return self.IP == rhs.IP
        } else {
            return false
        }
    }
    override open var hash: Int {
        return self.IP.hash
//        let acceptableChars = NSCharacterSet.init(charactersInString: "1234567890")
//        var str = "1" + IP
//        str = String(str.characters.filter { acceptableChars.containsCharacter($0) })
//        return Int.init(str)!
    }
    open var keepaliveTimer: Timer?
    open var lastReceivedOrSentData: Date = Date.init(timeIntervalSince1970: 0)
}

@objc public protocol BluepeerSessionManagerDelegate {
    @objc optional func peerDidConnect(_ peerRole: RoleType, peer: BPPeer)
    @objc optional func peerDidDisconnect(_ peerRole: RoleType, peer: BPPeer)
    @objc optional func peerConnectionAttemptFailed(_ peerRole: RoleType, peer: BPPeer?, isAuthRejection: Bool)
    @objc optional func peerConnectionRequest(_ peer: BPPeer, invitationHandler: @escaping (Bool) -> Void) // was named: sessionConnectionRequest
    @objc optional func browserFoundPeer(_ role: RoleType, peer: BPPeer, inviteBlock: @escaping (_ connect: Bool, _ timeoutForInvite: TimeInterval) -> Void)
    @objc optional func browserLostPeer(_ role: RoleType, peer: BPPeer)
}

@objc public protocol BluepeerDataDelegate {
    func didReceiveData(_ data: Data, fromPeer peerID: BPPeer)
}

@objc open class BluepeerObject: NSObject {
    
    var delegateQueue: DispatchQueue?
    var serverSocket: GCDAsyncSocket?
    var publisher: HHServicePublisher?
    var browser: HHServiceBrowser?
    var overBluetoothOnly: Bool = false
    open var advertising: Bool = false
    open var browsing: Bool = false
    open var serviceType: String
    var serverPort: UInt16 = 0
    var versionString: String = "unknown"
    var displayName: String = UIDevice.current.name
    var sanitizedDisplayName: String {
        // sanitize name
        var retval = self.displayName.lowercased()
        if retval.characters.count > 15 {
            retval = retval.substring(to: retval.characters.index(retval.startIndex, offsetBy: 15))
        }
        let acceptableChars = CharacterSet.init(charactersIn: "abcdefghijklmnopqrstuvwxyz1234567890-")
        retval = String(retval.characters.map { (char: Character) in
            if acceptableChars.containsCharacter(char) == false {
                return "-"
            } else {
                return char
            }
        })
        return retval
    }
    
    weak open var sessionDelegate: BluepeerSessionManagerDelegate?
    weak open var dataDelegate: BluepeerDataDelegate?
    open var peers = Set<BPPeer>()
    var servicesBeingResolved = Set<HHService>()
    open var bluetoothState : BluetoothState = .unknown
    var bluetoothPeripheralManager: CBPeripheralManager
    open var bluetoothBlock: ((_ bluetoothState: BluetoothState) -> Void)?
    open var disconnectOnWillResignActive: Bool = false {
        didSet {
            if disconnectOnWillResignActive {
                NotificationCenter.default.addObserver(self, selector: #selector(willResignActive), name: NSNotification.Name.UIApplicationWillResignActive, object: nil)
            } else {
                NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIApplicationWillResignActive, object: nil)
            }
        }
    }
    let headerTerminator: Data = "\r\n\r\n".data(using: String.Encoding.utf8)! // same as HTTP. But header content here is just a number, representing the byte count of the incoming nsdata.
    let keepAliveHeader: Data = "0 ! 0 ! 0 ! 0 ! 0 ! 0 ! 0 ! ".data(using: String.Encoding.utf8)! // A special header kept to avoid timeouts
    let socketQueue = DispatchQueue(label: "xaphod.bluepeer.socketQueue", attributes: [])
    
    enum DataTag: Int {
        case tag_HEADER = 1
        case tag_BODY = 2
        case tag_WRITING = 3
        case tag_AUTH = 4
        case tag_NAME = 5
    }
    
    enum Timeouts: Double {
        case header = 40 // keepAlive packets (32bytes) will be sent every HEADER-10 seconds
        case body = 90
    }
    
    // if queue isn't given, main queue is used
    public init(serviceType: String, displayName:String?, queue:DispatchQueue?, serverPort: UInt16, overBluetoothOnly:Bool, bluetoothBlock: ((_ bluetoothState: BluetoothState)->Void)?) { // serviceType must be 1-15 chars, only a-z0-9 and hyphen, eg "xd-blueprint"
        self.serverPort = serverPort
        self.serviceType = "_" + serviceType + "._tcp"
        self.overBluetoothOnly = overBluetoothOnly
        self.delegateQueue = queue
        self.bluetoothPeripheralManager = CBPeripheralManager.init(delegate: nil, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey:0])
        
        super.init()

        if let name = displayName {
            self.displayName = name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }

        if let bundleVersionString = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            versionString = bundleVersionString
        }

        self.bluetoothBlock = bluetoothBlock
        self.bluetoothPeripheralManager = CBPeripheralManager.init(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey:0])
        NSLog("Initialized BluepeerObject. Name: \(self.displayName), bluetoothOnly: \(overBluetoothOnly ? "yes" : "no")")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        self.killAllKeepaliveTimers()
    }
    
    // Note: only disconnect is handled. My delegate is expected to reconnect if needed.
    func willResignActive() {
        NSLog("BluepeerObject: willResignActive, disconnecting.")
        stopBrowsing()
        stopAdvertising()
        disconnectSession()
    }
    
    open func disconnectSession() {
        // don't close serverSocket: expectation is that only stopAdvertising does this
        // loop through peers, disconenct all sockets
        for peer in self.peers {
            NSLog("BluepeerObject disconnectSession: disconnecting \(peer.IP)")
            peer.socket?.delegate = nil // we don't want to run our disconnection logic below
            peer.socket?.disconnect()
            peer.socket = nil
            peer.state = .notConnected
        }
        self.killAllKeepaliveTimers()
    }
    
    open func connectedRoleCount(_ role: RoleType) -> Int {
        return self.peers.filter({ $0.role == role && $0.state == .connected }).count
    }
    
    open func startAdvertising(_ role: RoleType) {
        if self.advertising == true {
            NSLog("BluepeerObject: Already advertising (no-op)")
            return
        }

        NSLog("BluepeerObject: starting advertising using port %d", serverPort)

        // type must be like: _myexampleservice._tcp  (no trailing .)
        // txtData: let's use this for RoleType. For now just shove RoleType in there!
        // txtData, from http://www.zeroconf.org/rendezvous/txtrecords.html: Using TXT records larger than 1300 bytes is NOT RECOMMENDED at this time. The format of the data within a DNS TXT record is zero or more strings, packed together in memory without any intervening gaps or padding bytes for word alignment. The format of each constituent string within the DNS TXT record is a single length byte, followed by 0-255 bytes of text data.
    
        // Could use the NSNetService version of this (TXTDATA maker), it'd be easier :)
        let swiftdict = ["role":"Server"] // assume I am a Server if I am told to start advertising
        let cfdata: Unmanaged<CFData>? = CFNetServiceCreateTXTDataWithDictionary(kCFAllocatorDefault, swiftdict as! CFDictionary)
        let txtdata = cfdata?.takeUnretainedValue()
        guard let _ = txtdata else {
            NSLog("BluepeerObject: ERROR could not create TXTDATA nsdata")
            return
        }
        self.publisher = HHServicePublisher.init(name: self.sanitizedDisplayName, type: self.serviceType, domain: "local.", txtData: txtdata as Data!, port: UInt(serverPort), includeP2P: true)
        
        guard let publisher = self.publisher else {
            NSLog("BluepeerObject: could not create publisher")
            return
        }
        publisher.delegate = self
        let starting = publisher.beginPublishOverBluetoothOnly(self.overBluetoothOnly)
        if !starting {
            NSLog("BluepeerObject ERROR: could not start advertising")
            self.publisher = nil
        }
        // serverSocket is created in didPublish delegate (from HHServicePublisherDelegate) below
    }
    
    open func stopAdvertising() {
        if (self.advertising) {
            guard let publisher = self.publisher else {
                NSLog("BluepeerObject: publisher is MIA while advertising set true! ERROR. Setting advertising=false")
                self.advertising = false
                return
            }
            publisher.endPublish()
            NSLog("BluepeerObject: advertising stopped")
        } else {
            NSLog("BluepeerObject: no advertising to stop (no-op)")
        }
        self.publisher = nil
        self.advertising = false
        if let socket = self.serverSocket {
            socket.delegate = nil
            socket.disconnect()
            self.serverSocket = nil
            NSLog("BluepeerObject: destroyed serverSocket")
        }
    }
    
    open func startBrowsing() {
        if self.browsing == true {
            NSLog("BluepeerObject: Already browsing (no-op)")
            return
        }

        self.browser = HHServiceBrowser.init(type: self.serviceType, domain: "local.", includeP2P: true)
        guard let browser = self.browser else {
            NSLog("BluepeerObject: ERROR, could not create browser")
            return
        }
        browser.delegate = self
        self.browsing = browser.beginBrowseOverBluetoothOnly(self.overBluetoothOnly)
        NSLog("BluepeerObject: now browsing")
    }
    
    open func stopBrowsing() {
        if (self.browsing) {
            guard let browser = self.browser else {
                NSLog("BluepeerObject: browser is MIA while browsing set true! ERROR. Setting browsing=false")
                self.browsing = false
                return
            }
            browser.endBrowse()
            NSLog("BluepeerObject: browsing stopped")
        } else {
            NSLog("BluepeerObject: no browsing to stop (no-op)")
        }
        self.browser = nil
        self.browsing = false
    }
    
    
    // If specified, peers takes precedence.
    open func sendData(_ datas: [Data], toPeers:[BPPeer]) throws {
        for data in datas {
            NSLog("BluepeerObject: sending data size \(data.count) to \(toPeers.count) peers")
            for peer in toPeers {
                self.sendDataInternal(peer, data: data)
            }
        }
    }
    
    open func sendData(_ datas: [Data], toRole: RoleType) throws {
        let targetPeers: [BPPeer] = peers.filter({
            if toRole != .all {
                return $0.role == toRole && $0.state == .connected
            } else {
                return $0.state == .connected
            }
        })
    
        for data in datas {
            if data.count == 0 {
                continue
            }
            NSLog("BluepeerObject sending data size \(data.count) to \(targetPeers.count) peers")
            for peer in targetPeers {
                self.sendDataInternal(peer, data: data)
            }
        }
    }

    func sendDataInternal(_ peer: BPPeer, data: Data) {
        // send header first. Then separator. Then send body.
        var length: UInt = UInt(data.count)
        let senddata = NSMutableData.init(bytes: &length, length: MemoryLayout<UInt>.size)
        senddata.append(self.headerTerminator)
        senddata.append(data)
        peer.socket?.write(senddata as Data, withTimeout: Timeouts.body.rawValue, tag: DataTag.tag_WRITING.rawValue)
    }
    
    func scheduleNextKeepaliveTimer(_ peer: BPPeer) {
        if peer.state != .connected {
            return
        }
        if peer.keepaliveTimer?.isValid == true && abs(peer.lastReceivedOrSentData.timeIntervalSinceNow) < 5.0 {
            // flood protection
            return
        }
        peer.lastReceivedOrSentData = Date.init()
        
        DispatchQueue.main.async(execute: {
            let delay: TimeInterval = Timeouts.header.rawValue - 5.0 - (Double(arc4random_uniform(10000)) / Double(1000)) // definitely 5s before HEADER timeout, or as much as 15s before
            if peer.keepaliveTimer?.isValid == true {
                NSLog("BluepeerObject: keepalive rescheduled for \(peer.displayName) in \(delay)s")
                peer.keepaliveTimer?.fireDate = Date.init(timeIntervalSinceNow: delay)
            } else {
                NSLog("BluepeerObject: keepalive INITIAL SCHEDULING for \(peer.displayName) in \(delay)s")
                peer.keepaliveTimer = Timer.scheduledTimer(timeInterval: delay, target: self, selector: #selector(self.keepAliveTimerFired), userInfo: ["peer":peer], repeats: true)
            }
        })
    }
    
    func keepAliveTimerFired(_ timer: Timer) {
        guard let ui = timer.userInfo as? Dictionary<String, AnyObject> else {
            assert(false, "ERROR")
            return
        }
        guard let peer = ui["peer"] as? BPPeer else {
            assert(false, "I'm expecting keepAlive timers can always find their peers, ie the peers don't get erased")
            return
        }
        if peer.state != .connected {
            NSLog("BluepeerObject: keepAlive timer finds peer isn't connected (no-op)")
        } else {
            var senddata = NSData.init(data: self.keepAliveHeader) as Data
            senddata.append(self.headerTerminator)
            peer.socket?.write(senddata, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_WRITING.rawValue)
            NSLog("BluepeerObject: send keepAlive to \(peer.displayName) @ \(peer.IP)")
        }
    }
    
    func killAllKeepaliveTimers() {
        for peer in self.peers {
            peer.keepaliveTimer?.invalidate()
            peer.keepaliveTimer = nil
        }
    }
    
    func dispatch_on_delegate_queue(_ block: @escaping ()->()) {
        if let queue = self.delegateQueue {
            queue.async(execute: block)
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
    
    open func getBrowser(_ completionBlock: @escaping (Bool) -> ()) -> UIViewController? {
        let initialVC = self.getStoryboard()?.instantiateInitialViewController()
        var browserVC = initialVC
        if let nav = browserVC as? UINavigationController {
            browserVC = nav.topViewController
        }
        guard let browser = browserVC as? BluepeerBrowserViewController else {
            assert(false, "ERROR - storyboard layout changed")
            return nil
        }
        browser.bluepeerObject = self
        browser.browserCompletionBlock = completionBlock
        return initialVC
    }
    
    func getStoryboard() -> UIStoryboard? {
        guard let bundlePath = Bundle.init(for: BluepeerObject.self).path(forResource: "Bluepeer", ofType: "bundle") else {
            assert(false, "ERROR: could not load bundle")
            return nil
        }
        return UIStoryboard.init(name: "Bluepeer", bundle: Bundle.init(path: bundlePath))
    }
}

extension GCDAsyncSocket {
    var peer: BPPeer? {
        guard let bo = self.delegate as? BluepeerObject else {
            return nil
        }
        guard let peer = bo.peers.filter({ $0.socket == self }).first else {
            return nil
        }
        return peer
    }
}

extension BluepeerObject : HHServicePublisherDelegate {
    public func serviceDidPublish(_ servicePublisher: HHServicePublisher!) {
        self.advertising = true

        // create serverSocket
        if let socket = self.serverSocket {
            socket.delegate = nil
            socket.disconnect()
            self.serverSocket = nil
        }
        
        self.serverSocket = GCDAsyncSocket.init(delegate: self, delegateQueue: socketQueue)
        guard let serverSocket = self.serverSocket else {
            NSLog("BluepeerObject: ERROR - Could not create serverSocket")
            return
        }
        
        do {
            try serverSocket.accept(onPort: serverPort)
        } catch {
            NSLog("BluepeerObject: ERROR accepting on serverSocket")
            return
        }
        
        NSLog("BluepeerObject: now advertising for service \(serviceType)")
    }
    
    public func serviceDidNotPublish(_ servicePublisher: HHServicePublisher!) {
        self.advertising = false
        NSLog("BluepeerObject: ERROR: serviceDidNotPublish")
    }
}

extension BluepeerObject : HHServiceBrowserDelegate {
    public func serviceBrowser(_ serviceBrowser: HHServiceBrowser!, didFind service: HHService!, moreComing: Bool) {
        if self.browsing == false {
            return
        }
        if service.type == self.serviceType {
            service.delegate = self
            self.servicesBeingResolved.insert(service)
            service.beginResolveOnlyOverBluetooth(self.overBluetoothOnly)
        }
    }
    
    public func serviceBrowser(_ serviceBrowser: HHServiceBrowser!, didRemove service: HHService!, moreComing: Bool) {
        NSLog("BluepeerObject: didRemoveService \(service.name)")
        if service.name != nil {
            let peer: BPPeer? = self.peers.filter({ $0.displayName == service.name }).first
            if let peer = peer {
                self.dispatch_on_delegate_queue({
                    self.sessionDelegate?.browserLostPeer?(peer.role, peer: peer)
                })
            }
        }
    }
}

extension BluepeerObject : HHServiceDelegate {
    public func serviceDidResolve(_ service: HHService!) {
        self.servicesBeingResolved.remove(service)
        if self.browsing == false {
            return
        }
        
        guard let txtdata = service.txtData else {
            NSLog("BluepeerObject: serviceDidResolve IGNORING service because no txtData found")
            return
        }
        
        let cfdict: Unmanaged<CFDictionary>? = CFNetServiceCreateDictionaryWithTXTData(kCFAllocatorDefault, txtdata as CFData)
        guard let _ = cfdict else {
            NSLog("BluepeerObject: serviceDidResolve IGNORING service because txtData was invalid")
            return
        }
        let dict: NSDictionary = cfdict!.takeUnretainedValue()
        guard let roleData = dict["role"] as? Data else {
            NSLog("BluepeerObject: serviceDidResolve IGNORING service because role was missing")
            return
        }
        let roleStr = String.init(data: roleData, encoding: String.Encoding.utf8)
        let role = RoleType.roleFromString(roleStr)
        if role == .unknown {
            assert(false, "Expecting a role that isn't unknown here")
            return
        }
        
        NSLog("BluepeerObject: serviceDidResolve type: \(service.type), name: \(service.name), role: \(roleStr)")
        
        guard let delegate = self.sessionDelegate else {
            NSLog("BluepeerObject: WARNING, ignoring resolved service because sessionDelegate is not set")
            return
        }
        
        guard var addressStr = service.resolvedIPAddresses.first as? String else {
            NSLog("BluepeerObject: serviceDidResolve IGNORING service because could not get address")
            return
        }

        if service.resolvedIPAddresses.count > 1 {
            // Althoug DNS gets published via Bluetooth only if onlyBluetooth is set, can still see wifi IP addresses. So examine IPs and prefer bluetooth-looking IP if onlyBluetooth is set, otherwise stick with first one
            var blueIP: String?
            
            for thisIP in service.resolvedIPAddresses {
                if let thisIPStr = thisIP as? String {
                    if thisIPStr.hasPrefix("169.254") { // WARNING: HARDCODED BLUETOOTH IP PREFIX FOR IOS
                        blueIP = thisIPStr
                        break
                    }
                }
            }
            if blueIP != nil && self.overBluetoothOnly {
                NSLog("BluepeerObject: serviceDidResolve preferring 169.254.* Bluetooth IP since overBluetoothOnly is set")
                addressStr = blueIP!
            }
        }
        
        guard var port = service.resolvedPortNumbers.first as? NSNumber else {
            NSLog("BluepeerObject: serviceDidResolve IGNORING service because could not get port")
            return
        }
        
        if service.resolvedPortNumbers.count == service.resolvedIPAddresses.count {
            var index: Int = 0
            for i in (0..<service.resolvedIPAddresses.count) {
                if (service.resolvedIPAddresses[i] as! String == addressStr) {
                    index = i
                    break
                }
            }
            
            port = service.resolvedPortNumbers[index] as! NSNumber
        }
        
        let newPeer = BPPeer.init()
        newPeer.role = role
        newPeer.displayName = service.name
        newPeer.IP = addressStr
        self.addPeer(newPeer)
        
        self.dispatch_on_delegate_queue({
            delegate.browserFoundPeer!(role, peer: newPeer, inviteBlock: { (connect, timeoutForInvite) in
                self.stopBrowsing() // stop browsing once user has done something
                if connect {
                    do {
                        NSLog("... trying to connect...")
                        newPeer.socket = GCDAsyncSocket.init(delegate: self, delegateQueue: self.socketQueue)
                        newPeer.state = .connecting
                        try newPeer.socket?.connect(toHost: addressStr, onPort: port.uint16Value, withTimeout: timeoutForInvite)
                    } catch {
                        NSLog("BluepeerObject: could not start connectToAdddress.")
                    }
                } else {
                    NSLog("... got told NOT to connect.")
                    newPeer.state = .notConnected
                }
            })
        })
    }
    
    public func serviceDidNotResolve(_ service: HHService!) {
        NSLog("BluepeerObject: ERROR, service did not resolve: \(service.name)")
        self.servicesBeingResolved.remove(service)
    }
    
    public func addPeer(_ newPeer: BPPeer) {
        let replaced = self.peers.contains(newPeer)
        self.peers.insert(newPeer)
        if replaced {
            NSLog("BluepeerObject: replaced peer with IP \(newPeer.IP)")
        } else {
            NSLog("BluepeerObject: added new peer with IP \(newPeer.IP)")
        }
    }
}


extension BluepeerObject : GCDAsyncSocketDelegate {
    
    public func socket(_ sock: GCDAsyncSocket, didAcceptNewSocket newSocket: GCDAsyncSocket) {
        
        if self.sessionDelegate != nil {
            guard let connectedHost = newSocket.connectedHost else {
                NSLog("BluepeerObject: ERROR, accepted newSocket has no connectedHost (no-op)")
                return
            }
            NSLog("BluepeerObject: accepting new connection from \(newSocket.connectedHost)")
            newSocket.delegate = self
            let newPeer = BPPeer.init()
            newPeer.state = .awaitingAuth
            newPeer.role = .client
            newPeer.IP = connectedHost
            newPeer.socket = newSocket
            self.addPeer(newPeer)
            
            // CONVENTION: CLIENT sends SERVER 32 bytes of its name -- UTF-8 string
            newSocket.readData(toLength: 32, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_NAME.rawValue)
        } else {
            NSLog("BluepeerObject: WARNING, ignoring connection attempt because I don't have a sessionDelegate assigned")
        }
    }
    
    public func socket(_ sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
        guard let peer = sock.peer else {
            assert(false, "BluepeerObject: programming error, expected to find a peer already in didConnectToHost")
            return
        }
        peer.state = .awaitingAuth
        NSLog("BluepeerObject: got to state = awaitingAuth with \(sock.connectedHost), sending name then awaiting ACK ('0')")
        
        // make 32-byte UTF-8 name
        let strData = NSMutableData.init(capacity: 32)
        for c in self.displayName.characters {
            if let thisData = String.init(c).data(using: String.Encoding.utf8) {
                if thisData.count + (strData?.length)! < 32 {
                    strData?.append(thisData)
                } else {
                    NSLog("BluepeerObject: max displayName length reached, truncating")
                    break
                }
            }
        }
        // pad to 32 bytes!
        let paddedStrData: NSMutableData = ("                                ".data(using: String.Encoding.utf8) as NSData?)?.mutableCopy() as! NSMutableData // that's 32 spaces :)
        paddedStrData.replaceBytes(in: NSMakeRange(0, strData!.length), withBytes: (strData?.bytes)!)
        sock.write(paddedStrData as Data, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_WRITING.rawValue)
        
        // now await auth
        sock.readData(toLength: 1, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_AUTH.rawValue)
    }
    
    func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: NSError?) {
        guard let peer = sock.peer else {
            NSLog("BluepeerObject socketDidDisconnect: WARNING, expected to find a peer")
            sock.delegate = nil
            self.dispatch_on_delegate_queue({
                self.sessionDelegate?.peerConnectionAttemptFailed?(.unknown, peer: nil, isAuthRejection: false)
            })
            return
        }
        let oldState = peer.state
        peer.state = .notConnected
        peer.keepaliveTimer?.invalidate()
        peer.keepaliveTimer = nil
        peer.socket = nil
        sock.delegate = nil
        NSLog("BluepeerObject: \(peer.displayName) @ \(peer.IP) disconnected")
        switch oldState {
        case .connected:
            self.dispatch_on_delegate_queue({
                self.sessionDelegate?.peerDidDisconnect?(peer.role, peer: peer)
            })
        case .notConnected:
            assert(false, "ERROR: state is being tracked wrong")
        case .connecting, .awaitingAuth:
            self.dispatch_on_delegate_queue({
                self.sessionDelegate?.peerConnectionAttemptFailed?(peer.role, peer: peer, isAuthRejection: oldState == .awaitingAuth)
            })
        }
    }
    
    public func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
        guard let peer = sock.peer else {
            assert(false, "BluepeerObject: programming error, expected to find a peer in didReadData")
            return
        }
        self.scheduleNextKeepaliveTimer(peer)

        if tag == DataTag.tag_AUTH.rawValue {
            assert(data.count == 1, "ERROR: not right length of bytes")
            var ack: UInt8 = 1
            (data as NSData).getBytes(&ack, length: 1)
            assert(ack == 0, "ERROR: not the right ACK")
            assert(peer.state == .awaitingAuth, "ERROR: expect I only get this while awaiting auth")
            peer.state = .connected // CLIENT becomes connected
            self.dispatch_on_delegate_queue({
                self.sessionDelegate?.peerDidConnect!(peer.role, peer: peer)
            })
            sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
            
        } else if tag == DataTag.tag_HEADER.rawValue {
            // first, strip the trailing headerTerminator
            let range = 0..<data.count-self.headerTerminator.count
            let dataWithoutTerminator = data.subdata(in: Range(range))
            if dataWithoutTerminator == self.keepAliveHeader {
                NSLog("BluepeerObject: got keepalive")
                sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
            } else {
                var length: UInt = 0
                (dataWithoutTerminator as NSData).getBytes(&length, length: MemoryLayout<UInt>.size)
                NSLog("BluepeerObject: got header, reading %lu bytes...", length)
                sock.readData(toLength: length, withTimeout: Timeouts.body.rawValue, tag: DataTag.tag_BODY.rawValue)
            }
            
        } else if tag == DataTag.tag_NAME.rawValue {
            
            var name = String.init(data: data, encoding: String.Encoding.utf8)
            if name == nil {
                name = "Unknown"
            }
            name = name?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            peer.displayName = name!

            if let delegate = self.sessionDelegate {
                self.dispatch_on_delegate_queue({
                    delegate.peerConnectionRequest!(peer, invitationHandler: { (inviteAccepted) in
                        if inviteAccepted && peer.state == .awaitingAuth && sock.isConnected == true {
                            peer.state = .connected // SERVER becomes connected
                            // CONVENTION: SERVER sends CLIENT a single 0 to show connection has been accepted, since it isn't possible to send a header for a payload of size zero except here.
                            sock.write(Data.init(count: 1), withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_WRITING.rawValue)
                            NSLog("... accepted (by my delegate)")
                            self.dispatch_on_delegate_queue({
                                self.sessionDelegate?.peerDidConnect?(.client, peer: peer)
                            })
                            sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
                        } else {
                            peer.state = .notConnected
                            sock.delegate = nil
                            sock.disconnect()
                            peer.socket = nil
                            NSLog("... rejected (by my delegate), or no longer connected")
                        }
                    })
                })
            }
            
        } else { // BODY case
            self.dispatch_on_delegate_queue({
                self.dataDelegate?.didReceiveData(data, fromPeer: peer)
            })
            sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
        }
    }
    
    public func socket(_ sock: GCDAsyncSocket, didWriteDataWithTag tag: Int) {
        guard let peer = sock.peer else {
            assert(false, "BluepeerObject: programming error, expected to find a peer in didWriteData")
            return
        }
        self.scheduleNextKeepaliveTimer(peer)
    }
    
    public func socket(_ sock: GCDAsyncSocket, didReadPartialDataOfLength partialLength: UInt, tag: Int) {
        guard let peer = sock.peer else {
            assert(false, "BluepeerObject: programming error, expected to find a peer in didReadPartialDataOfLength")
            return
        }
        self.scheduleNextKeepaliveTimer(peer)
    }
    
    public func socket(_ sock: GCDAsyncSocket, didWritePartialDataOfLength partialLength: UInt, tag: Int) {
        guard let peer = sock.peer else {
            assert(false, "BluepeerObject: programming error, expected to find a peer in didWritePartialDataOfLength")
            return
        }
        self.scheduleNextKeepaliveTimer(peer)
    }
    
    public func socket(_ sock: GCDAsyncSocket, shouldTimeoutReadWithTag tag: Int, elapsed: TimeInterval, bytesDone length: UInt) -> TimeInterval {
        return self.calcTimeExtension(sock, tag: tag)
    }
    
    public func socket(_ sock: GCDAsyncSocket, shouldTimeoutWriteWithTag tag: Int, elapsed: TimeInterval, bytesDone length: UInt) -> TimeInterval {
        return self.calcTimeExtension(sock, tag: tag)
    }
    
    public func calcTimeExtension(_ sock: GCDAsyncSocket, tag: Int) -> TimeInterval {
        guard let peer = sock.peer else {
            assert(false, "BluepeerObject: programming error, expected to find a peer")
            return 0
        }
        
        let timeSinceLastData = abs(peer.lastReceivedOrSentData.timeIntervalSinceNow)
        if timeSinceLastData > Timeouts.header.rawValue {
            // timeout!
            NSLog("BluepeerObject: socket timed out waiting for read/write. Tag: \(tag). Disconnecting.")
            sock.disconnect()
            return 0
        } else {
            // extend
            let retval: TimeInterval = Timeouts.header.rawValue / 3.0
            NSLog("BluepeerObject: extending socket timeout by \(retval)s bc I saw data \(timeSinceLastData)s ago")
            return retval
        }
    }
}

extension BluepeerObject: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        NSLog("Bluetooth status: ")
        switch (self.bluetoothPeripheralManager.state) {
        case .unknown:
            NSLog("Unknown")
            self.bluetoothState = .unknown
        case .resetting:
            NSLog("Resetting")
            self.bluetoothState = .other
        case .unsupported:
            NSLog("Unsupported")
            self.bluetoothState = .other
        case .unauthorized:
            NSLog("Unauthorized")
            self.bluetoothState = .other
        case .poweredOff:
            NSLog("PoweredOff")
            self.bluetoothState = .poweredOff
        case .poweredOn:
            NSLog("PoweredOn")
            self.bluetoothState = .poweredOn
        }
        self.bluetoothBlock?(self.bluetoothState)
    }
}

extension CharacterSet {
    func containsCharacter(_ c:Character) -> Bool {
        let s = String(c)
        let result = s.rangeOfCharacter(from: self)
        return result != nil
    }
}
