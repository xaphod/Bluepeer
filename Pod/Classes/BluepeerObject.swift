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
    case Unknown = 0
    case Server = 1
    case Client = 2
    case All = 3
    
    public var description: String {
        switch self {
        case .Server: return "Server"
        case .Client: return "Client"
        case .Unknown: return "Unknown"
        case .All: return "All"
        }
    }
    
    public static func roleFromString(roleStr: String?) -> RoleType {
        guard let roleStr = roleStr else {
            return .Unknown
        }
        switch roleStr {
            case "Server": return .Server
            case "Client": return .Client
            case "Unknown": return .Unknown
            case "All": return .All
        default: return .Unknown
        }
    }
}

@objc public enum BluetoothState: Int {
    case Unknown = 0
    case PoweredOff = 1
    case PoweredOn = 2
    case Other = 3
}


@objc public enum BPPeerState: Int, CustomStringConvertible {
    case NotConnected = 0
    case Connecting = 1
    case AwaitingAuth = 2
    case Connected = 3
    
    public var description: String {
        switch self {
        case .NotConnected: return "NotConnected"
        case .Connecting: return "Connecting"
        case .Connected: return "Connected"
        case .AwaitingAuth: return "AwaitingAuth"
        }
    }
}

@objc public class BPPeer: NSObject {
    public var displayName: String = ""
    public var socket: GCDAsyncSocket?
    public var role: RoleType = .Unknown
    public var state: BPPeerState = .NotConnected
    public var IP: String = ""
    override public func isEqual(object: AnyObject?) -> Bool {
        if let rhs = object as? BPPeer {
            return self.IP == rhs.IP
        } else {
            return false
        }
    }
    override public var hash: Int {
        return self.IP.hash
//        let acceptableChars = NSCharacterSet.init(charactersInString: "1234567890")
//        var str = "1" + IP
//        str = String(str.characters.filter { acceptableChars.containsCharacter($0) })
//        return Int.init(str)!
    }
    public var keepAliveTimer: NSTimer?
}

@objc public protocol BluepeerSessionManagerDelegate {
    optional func peerDidConnect(peerRole: RoleType, peer: BPPeer)
    optional func peerDidDisconnect(peerRole: RoleType, peer: BPPeer)
    optional func peerConnectionAttemptFailed(peerRole: RoleType, peer: BPPeer, isAuthRejection: Bool)
    optional func peerConnectionRequest(peer: BPPeer, invitationHandler: (Bool) -> Void) // was named: sessionConnectionRequest
    optional func browserFoundPeer(role: RoleType, peer: BPPeer, inviteBlock: (connect: Bool, timeoutForInvite: NSTimeInterval) -> Void)
    optional func browserLostPeer(role: RoleType, peer: BPPeer)
}

@objc public protocol BluepeerDataDelegate {
    func didReceiveData(data: NSData, fromPeer peerID: BPPeer)
}

@objc public class BluepeerObject: NSObject {
    
    var delegateQueue: dispatch_queue_t?
    var serverSocket: GCDAsyncSocket?
    var publisher: HHServicePublisher?
    var browser: HHServiceBrowser?
    var overBluetoothOnly: Bool = false
    public var advertising: Bool = false
    public var browsing: Bool = false
    public var serviceType: String
    var serverPort: UInt16 = 0
    var versionString: String = "unknown"
    var displayName: String = UIDevice.currentDevice().name
    var sanitizedDisplayName: String {
        // sanitize name
        var retval = self.displayName.lowercaseString
        if retval.characters.count > 15 {
            retval = retval.substringToIndex(retval.startIndex.advancedBy(15))
        }
        let acceptableChars = NSCharacterSet.init(charactersInString: "abcdefghijklmnopqrstuvwxyz1234567890-")
        retval = String(retval.characters.map { (char: Character) in
            if acceptableChars.containsCharacter(char) == false {
                return "-"
            } else {
                return char
            }
        })
        return retval
    }
    
    weak public var sessionDelegate: BluepeerSessionManagerDelegate?
    weak public var dataDelegate: BluepeerDataDelegate?
    public var peers = Set<BPPeer>()
    var servicesBeingResolved = Set<HHService>()
    public var bluetoothState : BluetoothState = .Unknown
    var bluetoothPeripheralManager: CBPeripheralManager
    public var bluetoothBlock: ((bluetoothState: BluetoothState) -> Void)?
    public var disconnectOnWillResignActive: Bool = false {
        didSet {
            if disconnectOnWillResignActive {
                NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(willResignActive), name: UIApplicationWillResignActiveNotification, object: nil)
            } else {
                NSNotificationCenter.defaultCenter().removeObserver(self, name: UIApplicationWillResignActiveNotification, object: nil)
            }
        }
    }
    let headerTerminator: NSData = "\r\n\r\n".dataUsingEncoding(NSUTF8StringEncoding)! // same as HTTP. But header content here is just a number, representing the byte count of the incoming nsdata.
    let keepAliveHeader: NSData = "0 ! 0 ! 0 ! 0 ! 0 ! 0 ! 0 ! ".dataUsingEncoding(NSUTF8StringEncoding)! // A special header kept to avoid timeouts
    let socketQueue = dispatch_queue_create("xaphod.bluepeer.socketQueue", nil)
    
    enum DataTag: Int {
        case TAG_HEADER = 1
        case TAG_BODY = 2
        case TAG_WRITING = 3
        case TAG_AUTH = 4
        case TAG_NAME = 5
    }
    
    enum Timeouts: Double {
        case HEADER = 40 // keepAlive packets (32bytes) will be sent every HEADER-10 seconds
        case BODY = 90
    }
    
    // if queue isn't given, main queue is used
    public init(serviceType: String, displayName:String?, queue:dispatch_queue_t?, serverPort: UInt16, overBluetoothOnly:Bool, bluetoothBlock: ((bluetoothState: BluetoothState)->Void)?) { // serviceType must be 1-15 chars, only a-z0-9 and hyphen, eg "xd-blueprint"
        self.serverPort = serverPort
        self.serviceType = "_" + serviceType + "._tcp"
        self.overBluetoothOnly = overBluetoothOnly
        self.delegateQueue = queue
        self.bluetoothPeripheralManager = CBPeripheralManager.init(delegate: nil, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey:0])
        
        super.init()

        if let name = displayName {
            self.displayName = name.stringByTrimmingCharactersInSet(NSCharacterSet.whitespaceAndNewlineCharacterSet())
        }

        if let bundleVersionString = NSBundle.mainBundle().infoDictionary?["CFBundleVersion"] as? String {
            versionString = bundleVersionString
        }

        self.bluetoothBlock = bluetoothBlock
        self.bluetoothPeripheralManager = CBPeripheralManager.init(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey:0])
        NSLog("Initialized BluepeerObject. Name: \(self.displayName), bluetoothOnly: \(overBluetoothOnly ? "yes" : "no")")
    }
    
    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
        self.killAllKeepAliveTimers()
    }
    
    // Note: only disconnect is handled. My delegate is expected to reconnect if needed.
    func willResignActive() {
        NSLog("BluepeerObject: willResignActive, disconnecting.")
        stopBrowsing()
        stopAdvertising()
        disconnectSession()
    }
    
    public func disconnectSession() {
        // don't close serverSocket: expectation is that only stopAdvertising does this
        // loop through peers, disconenct all sockets
        for peer in self.peers {
            NSLog("BluepeerObject disconnectSession: disconnecting \(peer.IP)")
            peer.socket?.delegate = nil // we don't want to run our disconnection logic below
            peer.socket?.disconnect()
            peer.socket = nil
            peer.state = .NotConnected
        }
        self.killAllKeepAliveTimers()
    }
    
    public func connectedRoleCount(role: RoleType) -> Int {
        return self.peers.filter({ $0.role == role && $0.state == .Connected }).count
    }
    
    public func startAdvertising(role: RoleType) {
        if self.advertising == true {
            NSLog("BluepeerObject: Already advertising (no-op)")
            return
        }

        NSLog("BluepeerObject: starting advertising using port %d", serverPort)

        // type must be like: _myexampleservice._tcp  (no trailing .)
        // txtData: let's use this for RoleType. For now just shove RoleType in there!
        // txtData, from http://www.zeroconf.org/rendezvous/txtrecords.html: Using TXT records larger than 1300 bytes is NOT RECOMMENDED at this time. The format of the data within a DNS TXT record is zero or more strings, packed together in memory without any intervening gaps or padding bytes for word alignment. The format of each constituent string within the DNS TXT record is a single length byte, followed by 0-255 bytes of text data.
    
        // Could use the NSNetService version of this (TXTDATA maker), it'd be easier :)
        let txtdict: CFDictionary = ["role":"Server"] // assume I am a Server if I am told to start advertising
        let cfdata: Unmanaged<CFData>? = CFNetServiceCreateTXTDataWithDictionary(kCFAllocatorDefault, txtdict)
        let txtdata = cfdata?.takeUnretainedValue()
        guard let _ = txtdata else {
            NSLog("BluepeerObject: ERROR could not create TXTDATA nsdata")
            return
        }
        self.publisher = HHServicePublisher.init(name: self.sanitizedDisplayName, type: self.serviceType, domain: "local.", txtData: txtdata, port: UInt(serverPort), includeP2P: true)
        
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
    
    public func stopAdvertising() {
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
    
    public func startBrowsing() {
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
    
    public func stopBrowsing() {
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
    public func sendData(datas: [NSData], toPeers:[BPPeer]) throws {
        for data in datas {
            NSLog("BluepeerObject: sending data size \(data.length) to \(toPeers.count) peers")
            for peer in toPeers {
                self.sendDataInternal(peer, data: data)
            }
        }
    }
    
    public func sendData(datas: [NSData], toRole: RoleType) throws {
        let targetPeers: [BPPeer] = peers.filter({
            if toRole != .All {
                return $0.role == toRole && $0.state == .Connected
            } else {
                return $0.state == .Connected
            }
        })
    
        for data in datas {
            if data.length == 0 {
                continue
            }
            NSLog("BluepeerObject sending data size \(data.length) to \(targetPeers.count) peers")
            for peer in targetPeers {
                self.sendDataInternal(peer, data: data)
            }
        }
    }

    func sendDataInternal(peer: BPPeer, data: NSData) {
        // send header first. Then separator. Then send body.
        dispatch_async(dispatch_get_main_queue(), {
            peer.keepAliveTimer?.invalidate()
            peer.keepAliveTimer = nil
        })
        var length: UInt = UInt(data.length)
        let headerdata = NSData.init(bytes: &length, length: sizeof(UInt))
        peer.socket?.writeData(headerdata, withTimeout: Timeouts.HEADER.rawValue, tag: DataTag.TAG_WRITING.rawValue)
        peer.socket?.writeData(self.headerTerminator, withTimeout: Timeouts.HEADER.rawValue, tag: DataTag.TAG_WRITING.rawValue)
        peer.socket?.writeData(data, withTimeout: Timeouts.BODY.rawValue, tag: DataTag.TAG_WRITING.rawValue)
        self.scheduleNextKeepAliveTimer(peer)
    }
    
    func scheduleNextKeepAliveTimer(peer: BPPeer) {
        dispatch_async(dispatch_get_main_queue(), {
            NSLog("BluepeerObject: keepalive scheduled for \(peer.displayName)")
            peer.keepAliveTimer = NSTimer.scheduledTimerWithTimeInterval(Timeouts.HEADER.rawValue - 10.0, target: self, selector: #selector(self.keepAliveTimerFired), userInfo: ["peer":peer], repeats: false)
        })
    }
    
    func keepAliveTimerFired(timer: NSTimer) {
        guard let peer = timer.userInfo?["peer"] as? BPPeer else {
            assert(false, "I'm expecting keepAlive timers can always find their peers, ie the peers don't get erased")
            return
        }
        if peer.state != .Connected {
            NSLog("BluepeerObject: keepAlive timer finds peer isn't connected (no-op)")
        } else {
            peer.socket?.writeData(self.keepAliveHeader, withTimeout: Timeouts.HEADER.rawValue, tag: DataTag.TAG_WRITING.rawValue)
            peer.socket?.writeData(self.headerTerminator, withTimeout: Timeouts.HEADER.rawValue, tag: DataTag.TAG_WRITING.rawValue)
            NSLog("BluepeerObject: send keepAlive to \(peer.displayName) @ \(peer.IP)")
            self.scheduleNextKeepAliveTimer(peer)
        }
    }
    
    func killAllKeepAliveTimers() {
        for peer in self.peers {
            peer.keepAliveTimer?.invalidate()
            peer.keepAliveTimer = nil
        }
    }
    
    func dispatch_on_delegate_queue(block: dispatch_block_t) {
        if let queue = self.delegateQueue {
            dispatch_async(queue, block)
        } else {
            dispatch_async(dispatch_get_main_queue(), block)
        }
    }
    
    public func getBrowser(completionBlock: Bool -> ()) -> UIViewController? {
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
        guard let bundlePath = NSBundle.init(forClass: BluepeerObject.self).pathForResource("Bluepeer", ofType: "bundle") else {
            assert(false, "ERROR: could not load bundle")
            return nil
        }
        return UIStoryboard.init(name: "Bluepeer", bundle: NSBundle.init(path: bundlePath))
    }
}

extension GCDAsyncSocket {
    var peer: BPPeer? {
        guard let bo = self.delegate as? BluepeerObject else {
            assert(false, "BluepeerObject: socket does not have delegate set to bluepeerObject");
            return nil
        }
        guard let peer = bo.peers.filter({ $0.socket == self }).first else {
            assert(false, "BluepeerObject: programming error, expected to find a peer")
            return nil
        }
        return peer
    }
}

extension BluepeerObject : HHServicePublisherDelegate {
    public func serviceDidPublish(servicePublisher: HHServicePublisher!) {
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
            try serverSocket.acceptOnPort(serverPort)
        } catch {
            NSLog("BluepeerObject: ERROR accepting on serverSocket")
            return
        }
        
        NSLog("BluepeerObject: now advertising for service \(serviceType)")
    }
    
    public func serviceDidNotPublish(servicePublisher: HHServicePublisher!) {
        self.advertising = false
        NSLog("BluepeerObject: ERROR: serviceDidNotPublish")
    }
}

extension BluepeerObject : HHServiceBrowserDelegate {
    public func serviceBrowser(serviceBrowser: HHServiceBrowser!, didFindService service: HHService!, moreComing: Bool) {
        if self.browsing == false {
            return
        }
        if service.type == self.serviceType {
            service.delegate = self
            self.servicesBeingResolved.insert(service)
            service.beginResolveOnlyOverBluetooth(self.overBluetoothOnly)
        }
    }
    
    public func serviceBrowser(serviceBrowser: HHServiceBrowser!, didRemoveService service: HHService!, moreComing: Bool) {
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
    public func serviceDidResolve(service: HHService!) {
        self.servicesBeingResolved.remove(service)
        if self.browsing == false {
            return
        }
        
        guard let txtdata = service.txtData else {
            NSLog("BluepeerObject: serviceDidResolve IGNORING service because no txtData found")
            return
        }
        
        let cfdict: Unmanaged<CFDictionary>? = CFNetServiceCreateDictionaryWithTXTData(kCFAllocatorDefault, txtdata)
        guard let _ = cfdict else {
            NSLog("BluepeerObject: serviceDidResolve IGNORING service because txtData was invalid")
            return
        }
        let dict: NSDictionary = cfdict!.takeUnretainedValue()
        guard let roleData = dict["role"] as? NSData else {
            NSLog("BluepeerObject: serviceDidResolve IGNORING service because role was missing")
            return
        }
        let roleStr = String.init(data: roleData, encoding: NSUTF8StringEncoding)
        let role = RoleType.roleFromString(roleStr)
        if role == .Unknown {
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
            delegate.browserFoundPeer!(role, peer: newPeer) { (connect, timeoutForInvite) in
                self.stopBrowsing() // stop browsing once user has done something
                if connect {
                    do {
                        NSLog("... trying to connect...")
                        newPeer.socket = GCDAsyncSocket.init(delegate: self, delegateQueue: self.socketQueue)
                        newPeer.state = .Connecting
                        try newPeer.socket?.connectToHost(addressStr, onPort: port.unsignedShortValue, withTimeout: timeoutForInvite)
                    } catch {
                        NSLog("BluepeerObject: could not start connectToAdddress.")
                    }
                } else {
                    NSLog("... got told NOT to connect.")
                    newPeer.state = .NotConnected
                }
            }
        })
    }
    
    public func serviceDidNotResolve(service: HHService!) {
        NSLog("BluepeerObject: ERROR, service did not resolve: \(service.name)")
        self.servicesBeingResolved.remove(service)
    }
    
    public func addPeer(newPeer: BPPeer) {
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
    
    public func socket(sock: GCDAsyncSocket, didAcceptNewSocket newSocket: GCDAsyncSocket) {
        
        if self.sessionDelegate != nil {
            guard let connectedHost = newSocket.connectedHost else {
                NSLog("BluepeerObject: ERROR, accepted newSocket has no connectedHost (no-op)")
                return
            }
            NSLog("BluepeerObject: accepting new connection from \(newSocket.connectedHost)")
            newSocket.delegate = self
            let newPeer = BPPeer.init()
            newPeer.state = .AwaitingAuth
            newPeer.role = .Client
            newPeer.IP = connectedHost
            newPeer.socket = newSocket
            self.addPeer(newPeer)
            
            // CONVENTION: CLIENT sends SERVER 32 bytes of its name -- UTF-8 string
            newSocket.readDataToLength(32, withTimeout: Timeouts.HEADER.rawValue, tag: DataTag.TAG_NAME.rawValue)
        } else {
            NSLog("BluepeerObject: WARNING, ignoring connection attempt because I don't have a sessionDelegate assigned")
        }
    }
    
    public func socket(sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
        guard let peer = sock.peer else {
            assert(false, "BluepeerObject: programming error, expected to find a peer already in didConnectToHost")
            return
        }
        peer.state = .AwaitingAuth
        NSLog("BluepeerObject: got to state = awaitingAuth with \(sock.connectedHost), sending name then awaiting ACK ('0')")
        
        // make 32-byte UTF-8 name
        let strData = NSMutableData.init(capacity: 32)
        for c in self.displayName.characters {
            if let thisData = String.init(c).dataUsingEncoding(NSUTF8StringEncoding) {
                if thisData.length + (strData?.length)! < 32 {
                    strData?.appendData(thisData)
                } else {
                    NSLog("BluepeerObject: max displayName length reached, truncating")
                    break
                }
            }
        }
        // pad to 32 bytes!
        let paddedStrData: NSMutableData = "                                ".dataUsingEncoding(NSUTF8StringEncoding)?.mutableCopy() as! NSMutableData // that's 32 spaces :)
        paddedStrData.replaceBytesInRange(NSMakeRange(0, strData!.length), withBytes: (strData?.bytes)!)
        sock.writeData(paddedStrData, withTimeout: Timeouts.HEADER.rawValue, tag: DataTag.TAG_WRITING.rawValue)
        
        // now await auth
        sock.readDataToLength(1, withTimeout: Timeouts.HEADER.rawValue, tag: DataTag.TAG_AUTH.rawValue)
    }
    
    public func socketDidDisconnect(sock: GCDAsyncSocket, withError err: NSError?) {
        guard let peer = sock.peer else {
            assert(false, "BluepeerObject: programming error, expected to find a peer in didDisconnect")
            return
        }
        let oldState = peer.state
        peer.state = .NotConnected
        peer.keepAliveTimer?.invalidate()
        peer.keepAliveTimer = nil
        peer.socket = nil
        sock.delegate = nil
        NSLog("BluepeerObject: \(peer.displayName) @ \(peer.IP) disconnected")
        switch oldState {
        case .Connected:
            self.dispatch_on_delegate_queue({
                self.sessionDelegate?.peerDidDisconnect!(peer.role, peer: peer)
            })
        case .NotConnected:
            assert(false, "ERROR: state is being tracked wrong")
        case .Connecting, .AwaitingAuth:
            self.dispatch_on_delegate_queue({
                self.sessionDelegate?.peerConnectionAttemptFailed?(peer.role, peer: peer, isAuthRejection: oldState == .AwaitingAuth)
            })
        }
    }
    
    public func socket(sock: GCDAsyncSocket, didReadData data: NSData, withTag tag: Int) {
        guard let peer = sock.peer else {
            assert(false, "BluepeerObject: programming error, expected to find a peer in didReadData")
            return
        }

        if tag == DataTag.TAG_AUTH.rawValue {
            assert(data.length == 1, "ERROR: not right length of bytes")
            var ack: UInt8 = 1
            data.getBytes(&ack, length: 1)
            assert(ack == 0, "ERROR: not the right ACK")
            assert(peer.state == .AwaitingAuth, "ERROR: expect I only get this while awaiting auth")
            peer.state = .Connected // CLIENT becomes connected
            self.dispatch_on_delegate_queue({
                self.sessionDelegate?.peerDidConnect!(peer.role, peer: peer)
            })
            self.scheduleNextKeepAliveTimer(peer)
            sock.readDataToData(self.headerTerminator, withTimeout: Timeouts.HEADER.rawValue, tag: DataTag.TAG_HEADER.rawValue)
        } else if tag == DataTag.TAG_HEADER.rawValue {
            // first, strip the trailing headerTerminator
            let dataWithoutTerminator = data.subdataWithRange(NSRange.init(location: 0, length: data.length - self.headerTerminator.length))
            if dataWithoutTerminator.isEqualToData(self.keepAliveHeader) {
                NSLog("BluepeerObject: got keepalive")
                sock.readDataToData(self.headerTerminator, withTimeout: Timeouts.HEADER.rawValue, tag: DataTag.TAG_HEADER.rawValue)
            } else {
                var length: UInt = 0
                dataWithoutTerminator.getBytes(&length, length: sizeof(UInt))
                NSLog("BluepeerObject: got header, reading %lu bytes...", length)
                sock.readDataToLength(length, withTimeout: Timeouts.BODY.rawValue, tag: DataTag.TAG_BODY.rawValue)
            }
        } else if tag == DataTag.TAG_NAME.rawValue {
            
            var name = String.init(data: data, encoding: NSUTF8StringEncoding)
            if name == nil {
                name = "Unknown"
            }
            name = name?.stringByTrimmingCharactersInSet(NSCharacterSet.whitespaceAndNewlineCharacterSet())
            peer.displayName = name!

            if let delegate = self.sessionDelegate {
                self.dispatch_on_delegate_queue({
                    delegate.peerConnectionRequest!(peer, invitationHandler: { (inviteAccepted) in
                        if inviteAccepted && peer.state == .AwaitingAuth && sock.isConnected == true {
                            peer.state = .Connected // SERVER becomes connected
                            var zero = UInt8(0) // CONVENTION: SERVER sends CLIENT a single 0 to show connection has been accepted, since it isn't possible to send a header for a payload of size zero except here.
                            sock.writeData(NSData.init(bytes: &zero, length: 1), withTimeout: Timeouts.HEADER.rawValue, tag: DataTag.TAG_WRITING.rawValue)
                            NSLog("... accepted (by my delegate)")
                            self.dispatch_on_delegate_queue({
                                self.sessionDelegate?.peerDidConnect!(.Client, peer: peer)
                            })
                            self.scheduleNextKeepAliveTimer(peer)
                            sock.readDataToData(self.headerTerminator, withTimeout: Timeouts.HEADER.rawValue, tag: DataTag.TAG_HEADER.rawValue)
                        } else {
                            peer.state = .NotConnected
                            sock.delegate = nil
                            sock.disconnect()
                            peer.socket = nil
                            NSLog("... rejected (by my delegate), or no longer connected")
                        }
                    })
                })
            }
        } else {
            self.dispatch_on_delegate_queue({
                self.dataDelegate?.didReceiveData(data, fromPeer: peer)
            })
            sock.readDataToData(self.headerTerminator, withTimeout: Timeouts.HEADER.rawValue, tag: DataTag.TAG_HEADER.rawValue)
        }
    }
    
    public func socket(sock: GCDAsyncSocket, shouldTimeoutReadWithTag tag: Int, elapsed: NSTimeInterval, bytesDone length: UInt) -> NSTimeInterval {
        NSLog("BluepeerObject: socket timed out waiting for read. Tag: \(tag). Disconnecting.")
        sock.disconnect()
        return 0
    }
    
    public func socket(sock: GCDAsyncSocket, shouldTimeoutWriteWithTag tag: Int, elapsed: NSTimeInterval, bytesDone length: UInt) -> NSTimeInterval {
        NSLog("BluepeerObject: socket timed out waiting for write. Tag: \(tag). Disconnecting.")
        sock.disconnect()
        return 0
    }
}

extension BluepeerObject: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(peripheral: CBPeripheralManager) {
        NSLog("Bluetooth status: ")
        switch (self.bluetoothPeripheralManager.state) {
        case .Unknown:
            NSLog("Unknown")
            self.bluetoothState = .Unknown
        case .Resetting:
            NSLog("Resetting")
            self.bluetoothState = .Other
        case .Unsupported:
            NSLog("Unsupported")
            self.bluetoothState = .Other
        case .Unauthorized:
            NSLog("Unauthorized")
            self.bluetoothState = .Other
        case .PoweredOff:
            NSLog("PoweredOff")
            self.bluetoothState = .PoweredOff
        case .PoweredOn:
            NSLog("PoweredOn")
            self.bluetoothState = .PoweredOn
        }
        self.bluetoothBlock?(bluetoothState: self.bluetoothState)
    }
}

extension NSCharacterSet {
    func containsCharacter(c:Character) -> Bool {
        let s = String(c)
        let result = s.rangeOfCharacterFromSet(self)
        return result != nil
    }
}