//
//  BluepeerObject.swift
//
//  Created by Tim Carr on 7/7/16.
//  Copyright © 2016 Tim Carr Photo. All rights reserved.
//

import Foundation
import CoreBluetooth
import CFNetwork
import CocoaAsyncSocket // NOTE: requires pod CocoaAsyncSocket
import HHServices
import dnssd

let kDNSServiceInterfaceIndexP2PSwift = UInt32.max-2 // TODO: ARGH THIS IS A SHITTY HACK! I HATE SWIFT TODAY!

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


public enum BPPeerState: Int, CustomStringConvertible {
    case notConnected = 0
    case connecting = 1
    case awaitingAuth = 2
    case authenticated = 3
    
    public var description: String {
        switch self {
        case .notConnected: return "NotConnected"
        case .connecting: return "Connecting"
        case .awaitingAuth: return "AwaitingAuth"
        case .authenticated: return "Authenticated"
        }
    }
}

@objc open class BPPeer: NSObject {
    open var displayName: String = "" // is HHService.name !
    fileprivate var socket: GCDAsyncSocket?
    open var role: RoleType = .unknown
    open var state: BPPeerState = .notConnected
    fileprivate var lastService: HHService?
    fileprivate var lastReannounce = Date.init(timeIntervalSince1970: 0)
    open var keepaliveTimer: Timer?
    open var lastReceivedData: Date = Date.init(timeIntervalSince1970: 0)
    open var connectBlock: (()->Void)?
    open var customData: [String:String]?
    override open var description: String {
        return "\n[name: " + displayName + ", state: " + state.description + ", role: " + role.description + ", socket: " + socket.debugDescription + ", lastService: " + lastService.debugDescription + ", lastReceivedData: " + lastReceivedData.description + ", keepAlive: " + keepaliveTimer.debugDescription + "]"
    }
}

@objc public protocol BluepeerMembershipRosterDelegate {
    @objc optional func peerDidConnect(_ peerRole: RoleType, peer: BPPeer)
    @objc optional func peerDidDisconnect(_ peerRole: RoleType, peer: BPPeer)
    @objc optional func peerConnectionAttemptFailed(_ peerRole: RoleType, peer: BPPeer?, isAuthRejection: Bool)
}

@objc public protocol BluepeerMembershipAdminDelegate {
    @objc optional func peerConnectionRequest(_ peer: BPPeer, invitationHandler: @escaping (Bool) -> Void) // was named: sessionConnectionRequest
    @objc optional func browserFoundPeer(_ role: RoleType, peer: BPPeer, customData: [String:String]?) // peer has connectBlock() that can be executed
    @objc optional func browserLostPeer(_ role: RoleType, peer: BPPeer)
}

@objc public protocol BluepeerDataDelegate {
    func didReceiveData(_ data: Data, fromPeer peerID: BPPeer)
}

@objc public protocol BluepeerLoggingDelegate {
    func didReadWrite(_ logString: String)
}

/* ADD TO POD FILE
 post_install do |installer_representation|
   installer_representation.pods_project.targets.each do |target|
     target.build_configurations.each do |config|
       if config.name != 'Release'
         config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['$(inherited)', 'DEBUG=1']
         config.build_settings['OTHER_SWIFT_FLAGS'] = ['$(inherited)', '-DDEBUG']
       end
     end
   end
 end
*/

func DLog(_ items: Any...) {
    #if DEBUG
        let formatter = DateFormatter.init()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        var str = ""
        for item in items {
            if let item = item as? String {
                str += item
            } else if let item = item as? AnyObject {
                str += item.debugDescription
            } else {
                str += String(describing: item)
            }
        }
        
        print("BP " + formatter.string(from: Date.init()) + " - " + str)
    #endif
}



@objc open class BluepeerObject: NSObject {
    
    var delegateQueue: DispatchQueue?
    var serverSocket: GCDAsyncSocket?
    var publisher: HHServicePublisher?
    var browser: HHServiceBrowser?
    var bluetoothOnly: Bool = false
    open var advertising: RoleType?
    var advertisingCustomData: [String:String]?
    open var browsing: Bool = false
    var onLastBackground: (advertising: RoleType?, browsing: Bool) = (nil, false)
    open var serviceType: String = ""
    var serverPort: UInt16 = 0
    var versionString: String = "unknown"
    var displayNameSanitized: String = ""
    var appIsInBackground = false
    
    weak open var membershipAdminDelegate: BluepeerMembershipAdminDelegate?
    weak open var membershipRosterDelegate: BluepeerMembershipRosterDelegate?
    weak open var dataDelegate: BluepeerDataDelegate?
    weak open var logDelegate: BluepeerLoggingDelegate?
    open var peers = [BPPeer]()
    open var bluetoothState : BluetoothState = .unknown
    var bluetoothPeripheralManager: CBPeripheralManager!
    open var bluetoothBlock: ((_ bluetoothState: BluetoothState) -> Void)?
    open var disconnectOnBackground: Bool = false
    let headerTerminator: Data = "\r\n\r\n".data(using: String.Encoding.utf8)! // same as HTTP. But header content here is just a number, representing the byte count of the incoming nsdata.
    let keepAliveHeader: Data = "0 ! 0 ! 0 ! 0 ! 0 ! 0 ! 0 ! ".data(using: String.Encoding.utf8)! // A special header kept to avoid timeouts
    let socketQueue = DispatchQueue(label: "xaphod.bluepeer.socketQueue", attributes: [])
    var browsingWorkaroundRestarts = 0
    
    enum DataTag: Int {
        case tag_HEADER = 1
        case tag_BODY = 2
        case tag_WRITING = 3
        case tag_AUTH = 4
        case tag_NAME = 5
    }
    
    enum Timeouts: Double {
        case header = 40
        case body = 90
        case keepAlive = 30
    }
    
    // if queue isn't given, main queue is used
    public init?(serviceType: String, displayName:String?, queue:DispatchQueue?, serverPort: UInt16, overBluetoothOnly:Bool, bluetoothBlock: ((_ bluetoothState: BluetoothState)->Void)?) {
        
        super.init()
        
        // serviceType must be 1-15 chars, only a-z0-9 and hyphen, eg "xd-blueprint"
        if serviceType.characters.count > 15 {
            assert(false, "ERROR: service name is too long")
            return nil
        }
        self.serviceType = "_" + self.sanitizeCharsToDNSChars(str: serviceType) + "._tcp"
        
        self.serverPort = serverPort
        self.bluetoothOnly = overBluetoothOnly
        self.delegateQueue = queue
        
        var name = UIDevice.current.name
        if let displayName = displayName {
            name = displayName
        }
        self.displayNameSanitized = self.sanitizeStringAsDNSName(str: name)

        if let bundleVersionString = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            versionString = bundleVersionString
        }

        self.bluetoothBlock = bluetoothBlock
        self.bluetoothPeripheralManager = CBPeripheralManager.init(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey:0])
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: NSNotification.Name.UIApplicationDidEnterBackground, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: NSNotification.Name.UIApplicationWillEnterForeground, object: nil)
        if #available(iOS 8.2, *) {
            NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: NSNotification.Name.NSExtensionHostDidEnterBackground, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: NSNotification.Name.NSExtensionHostWillEnterForeground, object: nil)
        } 
        
        DLog("Initialized BluepeerObject. Name: \(self.displayNameSanitized), bluetoothOnly: \(self.bluetoothOnly ? "yes" : "no")")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        self.killAllKeepaliveTimers() // probably moot: won't start deiniting until all timers are dead, because they have a strong ref to self
        self.disconnectSession()
        self.stopBrowsing()
        self.stopAdvertising()
        DLog("BluepeerObject: DEINIT FINISH")
    }
    
    // Note: if I disconnect, then my delegate is expected to reconnect if needed.
    func didEnterBackground() {
        self.appIsInBackground = true
        self.onLastBackground = (self.advertising, self.browsing)
        stopBrowsing()
        stopAdvertising()
        if disconnectOnBackground {
            disconnectSession()
            DLog("BluepeerObject: didEnterBackground - stopped browsing & advertising, and disconnected session")
        } else {
            DLog("BluepeerObject: didEnterBackground - stopped browsing & advertising")
        }
    }
    
    func willEnterForeground() {
        DLog("BluepeerObject: willEnterForeground")
        self.appIsInBackground = false
        if let role = self.onLastBackground.advertising {
            DLog("BluepeerObject: willEnterForeground, startAdvertising")
            startAdvertising(role, customData: self.advertisingCustomData)
        }
        if self.onLastBackground.browsing {
            DLog("BluepeerObject: willEnterForeground, startBrowsing")
            startBrowsing()
        }
    }
    
    func sanitizeCharsToDNSChars(str: String) -> String {
        let acceptableChars = CharacterSet.init(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz1234567890-")
        return String(str.characters.filter({ $0 != "'"}).map { (char: Character) in
            if acceptableChars.containsCharacter(char) == false {
                return "-"
            } else {
                return char
            }
        })
    }
    
    // per DNSServiceRegister called by HHServices, the String must be at most 63 bytes of UTF8 data. But, Bluepeer sends 32-byte name strings as part of its connection buildup, so limit this to max 32 bytes. The name is used to uniquely identify devices, and devices might have the same name (ie. "iPhone"), so append some random numbers to the end
    // returns: the given string with an identifier appended on the end, guaranteed to be max 32 bytes
    func sanitizeStringAsDNSName(str: String) -> String {
        // first sanitize name by getting rid of invalid chars
        var retval = self.sanitizeCharsToDNSChars(str: str)
        
        // we need to append "-NNNN" to the end, which is 5 bytes in UTF8. So, the name part can be max 32-5 bytes = 27 bytes
        // characters take up different amounts of bytes in UTF8, so let's be careful to count them
        var strData = Data.init(capacity: 32)
        
        // make 27-byte UTF-8 name
        for c in retval.characters {
            if let thisData = String.init(c).data(using: String.Encoding.utf8) {
                if thisData.count + (strData.count) <= 27 {
                    strData.append(thisData)
                } else {
                    break
                }
            } else {
                assert(false, "ERROR: non-UTF8 chars found")
            }
        }

        strData.append(String.init("-").data(using: String.Encoding.utf8)!)
        for _ in 1...4 {
            strData.append(String.init(arc4random_uniform(10)).data(using: String.Encoding.utf8)!)
        }
        
        retval = String.init(data: strData, encoding: String.Encoding.utf8)!
        DLog("BluepeerObject: sanitized \(str) to \(retval)")
        return retval
    }
    
    open func disconnectSession() {
        // don't close serverSocket: expectation is that only stopAdvertising does this
        // loop through peers, disconenct all sockets
        for peer in self.peers {
            DLog("BluepeerObject disconnectSession: disconnecting \(peer.displayName)")
            peer.socket?.synchronouslySetDelegate(nil) // we don't want to run our disconnection logic below
            peer.socket?.disconnect()
            peer.socket = nil
            peer.lastService?.endResolve()
            peer.lastService = nil
            peer.state = .notConnected
            peer.keepaliveTimer?.invalidate()
            peer.keepaliveTimer = nil
            peer.customData = nil
        }
        self.peers = [] // remove all peers!
    }
    
    open func connectedRoleCount(_ role: RoleType) -> Int {
        return self.peers.filter({ $0.role == role && $0.state == .authenticated }).count
    }
    
    open func connectedCount() -> Int {
        return self.peers.filter({ $0.state == .authenticated }).count
    }
    
    // specify customData if this is needed for browser to decide whether to connect or not
    open func startAdvertising(_ role: RoleType, customData: [String:String]?) {
        if let _ = self.advertising {
            DLog("BluepeerObject: Already advertising (no-op)")
            return
        }

        DLog("BluepeerObject: starting advertising using port \(serverPort)")

        // type must be like: _myexampleservice._tcp  (no trailing .)
        // txtData: let's use this for RoleType. For now just shove RoleType in there!
        // txtData, from http://www.zeroconf.org/rendezvous/txtrecords.html: Using TXT records larger than 1300 bytes is NOT RECOMMENDED at this time. The format of the data within a DNS TXT record is zero or more strings, packed together in memory without any intervening gaps or padding bytes for word alignment. The format of each constituent string within the DNS TXT record is a single length byte, followed by 0-255 bytes of text data.
    
        // Could use the NSNetService version of this (TXTDATA maker), it'd be easier :)
        var swiftdict: [String:String] = ["role":role.description]
        self.advertisingCustomData = customData
        if let customData = customData {
            swiftdict.merge(with: customData)
        }
        let cfdata: Unmanaged<CFData>? = CFNetServiceCreateTXTDataWithDictionary(kCFAllocatorDefault, swiftdict as CFDictionary)
        let txtdata = cfdata?.takeUnretainedValue()
        guard let _ = txtdata else {
            DLog("BluepeerObject: ERROR could not create TXTDATA nsdata")
            return
        }
        self.publisher = HHServicePublisher.init(name: self.displayNameSanitized, type: self.serviceType, domain: "local.", txtData: txtdata as Data!, port: UInt(serverPort))
        self.publisher?.mainDispatchQueue = socketQueue
        
        guard let publisher = self.publisher else {
            DLog("BluepeerObject: could not create publisher")
            return
        }
        publisher.delegate = self
        var starting: Bool
        if (self.bluetoothOnly) {
            starting = publisher.beginPublishOverBluetoothOnly()
        } else {
            starting = publisher.beginPublish()
        }
        if !starting {
            DLog("BluepeerObject ERROR: could not start advertising")
            self.publisher = nil
        }
        // serverSocket is created in didPublish delegate (from HHServicePublisherDelegate) below
        self.advertising = role
    }
    
    open func stopAdvertising() {
        if let _ = self.advertising {
            guard let publisher = self.publisher else {
                DLog("BluepeerObject: publisher is MIA while advertising set true! ERROR. Setting advertising=false")
                self.advertising = nil
                return
            }
            publisher.endPublish()
            DLog("BluepeerObject: advertising stopped")
        } else {
            DLog("BluepeerObject: no advertising to stop (no-op)")
        }
        self.publisher = nil
        self.advertising = nil
        if let socket = self.serverSocket {
            socket.synchronouslySetDelegate(nil)
            socket.disconnect()
            self.serverSocket = nil
            DLog("BluepeerObject: destroyed serverSocket")
        }
    }
    
    open func startBrowsing() {
        if self.browsing == true {
            DLog("BluepeerObject: Already browsing (no-op)")
            return
        }

        self.browser = HHServiceBrowser.init(type: self.serviceType, domain: "local.")
        self.browser?.mainDispatchQueue = socketQueue
        guard let browser = self.browser else {
            DLog("BluepeerObject: ERROR, could not create browser")
            return
        }
        browser.delegate = self
        if (self.bluetoothOnly) {
            self.browsing = browser.beginBrowseOverBluetoothOnly()
        } else {
            self.browsing = browser.beginBrowse()
        }
        DLog("BluepeerObject: now browsing")
    }
    
    open func stopBrowsing() {
        if (self.browsing) {
            if self.browser == nil {
                DLog("BluepeerObject: WARNING, browser is MIA while browsing set true! ")
            } else {
                self.browser!.endBrowse()
                DLog("BluepeerObject: browsing stopped")
            }
        } else {
            DLog("BluepeerObject: no browsing to stop")
        }
        self.browser = nil
        self.browsing = false
        for peer in self.peers {
            peer.lastService?.endResolve()
//            peer.dnsService = nil
//            peer.customData = nil
        }
    }
    
    open func sendData(_ datas: [Data], toPeers:[BPPeer]) throws {
        for data in datas {
            DLog("BluepeerObject: sending data size \(data.count) to \(toPeers.count) peers")
            for peer in toPeers {
                self.logDelegate?.didReadWrite("writeSendDataToPeers")
                self.sendDataInternal(peer, data: data)
            }
        }
    }
    
    open func sendData(_ datas: [Data], toRole: RoleType) throws {
        let targetPeers: [BPPeer] = peers.filter({
            if toRole != .all {
                return $0.role == toRole && $0.state == .authenticated
            } else {
                return $0.state == .authenticated
            }
        })
    
        for data in datas {
            if data.count == 0 {
                continue
            }
            DLog("BluepeerObject sending data size \(data.count) to \(targetPeers.count) peers")
            for peer in targetPeers {
                self.logDelegate?.didReadWrite("writeSendDataToRole")
                self.sendDataInternal(peer, data: data)
            }
        }
    }

    func sendDataInternal(_ peer: BPPeer, data: Data) {
        // send header first. Then separator. Then send body.
        // length: send as 4-byte, then 4 bytes of unused 0s for now. assumes endianness doesn't change between platforms, ie 23 00 00 00 not 00 00 00 23
        var length: UInt = UInt(data.count)
        let senddata = NSMutableData.init(bytes: &length, length: 4)
        let unused4bytesdata = NSMutableData.init(length: 4)!
        senddata.append(unused4bytesdata as Data)
        senddata.append(self.headerTerminator)
        senddata.append(data)
        
//        DLog("sendDataInternal writes: \((senddata as Data).hex), payload part: \(data.hex)")
        peer.socket?.write(senddata as Data, withTimeout: Timeouts.body.rawValue, tag: DataTag.tag_WRITING.rawValue)
    }
    
    func scheduleNextKeepaliveTimer(_ peer: BPPeer) {
        DispatchQueue.main.async(execute: { // timer needs main, don't want to do checks earlier than right before scheduling timer
            if peer.state != .authenticated || peer.socket == nil {
                return
            }

            peer.lastReceivedData = Date.init()

            if peer.keepaliveTimer?.isValid == true {
                return
            }

            let delay: TimeInterval = Timeouts.keepAlive.rawValue - 5 - (Double(arc4random_uniform(5000)) / Double(1000)) // keepAlive.rawValue - 5 - (up to 5)
            DLog("BluepeerObject: keepalive INITIAL SCHEDULING for \(peer.displayName) in \(delay)s")
            peer.keepaliveTimer = Timer.scheduledTimer(timeInterval: delay, target: self, selector: #selector(self.keepAliveTimerFired), userInfo: ["peer":peer], repeats: true)
        })
    }
    
    func keepAliveTimerFired(_ timer: Timer) {
        guard let ui = timer.userInfo as? Dictionary<String, AnyObject> else {
            assert(false, "ERROR")
            timer.invalidate()
            return
        }
        guard let peer = ui["peer"] as? BPPeer else {
            DLog("BluepeerObject: keepAlive timer didn't find a peer, invalidating timer")
            timer.invalidate()
            return
        }
        if peer.state != .authenticated || peer.socket == nil {
            DLog("BluepeerObject: keepAlive timer finds peer isn't authenticated(connected), invalidating timer")
            timer.invalidate()
            peer.keepaliveTimer = nil
        } else {
            var senddata = NSData.init(data: self.keepAliveHeader) as Data
            senddata.append(self.headerTerminator)
            self.logDelegate?.didReadWrite("writeKeepAlive to \(peer.displayName)")
            
//            DLog("keepAlivetimer writes: \(senddata.hex)")
            
            peer.socket?.write(senddata, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_WRITING.rawValue)
            DLog("BluepeerObject: send keepAlive to \(peer.displayName) @ \(peer.socket?.connectedHost)")
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
    
    func announcePeer(peer: BPPeer) {
        guard let delegate = self.membershipAdminDelegate else {
            DLog("BluepeerObject announcePeer: WARNING, no-op because membershipAdminDelegate is not set")
            return
        }

        if self.appIsInBackground == false {
            DLog("BluepeerObject announcePeer: announcing now with browserFoundPeer - call peer.connectBlock() to connect")
            self.dispatch_on_delegate_queue({
                delegate.browserFoundPeer?(peer.role, peer: peer, customData: peer.customData)
            })
        } else {
            DLog("BluepeerObject announcePeer: app is in BACKGROUND, no-op!")
        }
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
    public func serviceDidPublish(_ servicePublisher: HHServicePublisher) {
        // create serverSocket
        if let socket = self.serverSocket {
            socket.synchronouslySetDelegate(nil)
            socket.disconnect()
            self.serverSocket = nil
        }
        
        self.serverSocket = GCDAsyncSocket.init(delegate: self, delegateQueue: socketQueue)
        self.serverSocket?.isIPv4PreferredOverIPv6 = false
        guard let serverSocket = self.serverSocket else {
            DLog("BluepeerObject: ERROR - Could not create serverSocket")
            return
        }
        
        do {
            try serverSocket.accept(onPort: serverPort)
        } catch {
            DLog("BluepeerObject: ERROR accepting on serverSocket")
            return
        }
        
        DLog("BluepeerObject: now advertising for service \(serviceType)")
    }
    
    public func serviceDidNotPublish(_ servicePublisher: HHServicePublisher) {
        self.advertising = nil
        DLog("BluepeerObject: ERROR: serviceDidNotPublish")
    }
}

extension BluepeerObject : HHServiceBrowserDelegate {
    public func serviceBrowser(_ serviceBrowser: HHServiceBrowser, didFind service: HHService, moreComing: Bool) {
        if self.browsing == false {
            return
        }
        if self.displayNameSanitized == service.name { // names are made unique by having random numbers appended
            DLog("BluepeerObject: found my own published service, ignoring...")
            return
        }

        if service.type == self.serviceType {
            DLog("BluepeerObject: didFindService \(service.name), moreComing: \(moreComing)")
            service.delegate = self
            
            // if this peer exists, then add this as another address(es), otherwise add now
            var peer = self.peers.filter({ $0.displayName == service.name }).first
            
            if let peer = peer {
                DLog("BluepeerObject didFind: found existing peer \(peer.displayName), replacing with newer service!!!")
                peer.lastService?.delegate = nil
                peer.lastService?.endResolve()
                peer.lastService = service
                //                peer?.customData = nil
                DLog("BluepeerObject didFind: ...done")
            } else {
                peer = BPPeer.init()
                guard let peer = peer else { return }
                peer.displayName = service.name
                peer.lastService = service
                self.peers.append(peer)
                DLog("BluepeerObject didFind: created new peer \(peer.displayName). Peers(n=\(self.peers.count)) after adding: \(self.peers)")
            }
            
            let prots = UInt32(kDNSServiceProtocol_IPv4) | UInt32(kDNSServiceProtocol_IPv6)
            if (self.bluetoothOnly) {
                service.beginResolve(kDNSServiceInterfaceIndexP2PSwift, includeP2P: true, addressLookupProtocols: prots)
            } else {
                service.beginResolve(UInt32(kDNSServiceInterfaceIndexAny), includeP2P: true, addressLookupProtocols: prots)
            }
        }
    }
    
    public func serviceBrowser(_ serviceBrowser: HHServiceBrowser, didRemove service: HHService, moreComing: Bool) {
        let matchingPeers = self.peers.filter({ $0.lastService?.name == service.name })
        if matchingPeers.count == 0 {
            DLog("BluepeerObject: didRemoveService for service.name \(service.name) -- IGNORING because no peer found")
            return
        }
        for peer in matchingPeers {
            DLog("BluepeerObject: didRemoveService \(service.name)")
            // peer.customData = nil
            self.dispatch_on_delegate_queue({
                self.membershipAdminDelegate?.browserLostPeer?(peer.role, peer: peer)
            })
        }
    }
}

extension BluepeerObject : HHServiceDelegate {
    public func serviceDidResolve(_ service: HHService, moreComing: Bool) {
        if self.browsing == false {
            return
        }
        
        guard let txtdata = service.txtData else {
            DLog("BluepeerObject: serviceDidResolve IGNORING service because no txtData found")
            return
        }
        guard let hhaddresses: [HHAddressInfo] = service.resolvedAddressInfo, hhaddresses.count > 0 else {
            DLog("BluepeerObject: serviceDidResolve IGNORING service because could not get resolvedAddressInfo")
            return
        }
        
        let cfdict: Unmanaged<CFDictionary>? = CFNetServiceCreateDictionaryWithTXTData(kCFAllocatorDefault, txtdata as CFData)
        guard let _ = cfdict else {
            DLog("BluepeerObject: serviceDidResolve IGNORING service because txtData was invalid")
            return
        }
        let dict: NSDictionary = cfdict!.takeUnretainedValue()
        guard let rD = dict["role"] as? Data,
            let roleStr = String.init(data: rD, encoding: String.Encoding.utf8) else {
            DLog("BluepeerObject: serviceDidResolve IGNORING service because role was missing")
            return
        }
        let role = RoleType.roleFromString(roleStr)
        if role == .unknown {
            assert(false, "Expecting a role that isn't unknown here")
            return
        }

        // load custom data
        var customData = [String:String]()
        for (k, v) in dict {
            guard let k = k as? String,
                let vd = v as? Data,
                let v = String.init(data: vd, encoding: String.Encoding.utf8) else {
                assert(false, "Expecting [String:Data] dict")
                continue
            }
            
            if k == "role" {
                continue
            } else {
                customData[k] = v
            }
        }

        let matchingPeers = self.peers.filter({ $0.displayName == service.name })
        if matchingPeers.count != 1 {
            DLog("BluepeerObject: serviceDidResolve FAILED, expected 1 peer but found \(matchingPeers.count)")
            assert(false)
            return
        }
        let peer = matchingPeers.first!
        if let existingSvc = peer.lastService {
            existingSvc.endResolve()
        }
        peer.lastService = service
        peer.role = role
        peer.customData = customData
        DLog("BluepeerObject: serviceDidResolve for \(service.name) with addresses \(hhaddresses.count) - setting peer.role: \(roleStr), peer.state: \(peer.state)")
        
        var limitToBluetooth = self.bluetoothOnly
        let candidates = hhaddresses.filter({ $0.isCandidateAddress(bluetoothOnly: limitToBluetooth) })
        if peer.state != .notConnected {
            DLog("... has state!=notConnected, so no-op")
            return
        } else if candidates.count == 0 {
            DLog("... no candidates out of \(hhaddresses.count) addresses. moreComing = \(moreComing)")
            if hhaddresses.count > 1 && !moreComing {
                if (self.browsingWorkaroundRestarts >= 3) {
                    DLog(" *** workarounds exhausted! falling back to not bluetoothOnly")
                    self.browsingWorkaroundRestarts = 0
                    limitToBluetooth = false
                    let secondaryCandidates = hhaddresses.filter({ $0.isCandidateAddress(bluetoothOnly: limitToBluetooth) })
                    if (secondaryCandidates.count <= 0) {
                        DLog("... STILL no candidates. Bummer.")
                        return
                    }
                } else {
                    self.browsingWorkaroundRestarts += 1
                    DLog(" *** workaround for BT radio connection delay: restarting browsing, \(self.browsingWorkaroundRestarts) of 3")
                    self.stopBrowsing()
                    if let indexOfPeer = self.peers.index(of: peer) {
                        self.peers.remove(at: indexOfPeer)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.startBrowsing()
                    }
                    return
                }
            } else {
                return
            }
        }

        peer.connectBlock = {
            do {
                // pick the address to connect to INSIDE the block, because more addresses may have been added between announcement and inviteBlock being executed
                guard let hhaddresses = peer.lastService?.resolvedAddressInfo, hhaddresses.count > 0, var chosenAddress = hhaddresses.filter({ $0.isCandidateAddress(bluetoothOnly: limitToBluetooth) }).first else {
                    DLog("BluepeerObject connectBlock: no resolvedAddresses or candidates after invite accepted/rejected, BAILING")
                    return
                }
                
                // if we can use wifi, then use wifi if possible
                if !self.bluetoothOnly && !chosenAddress.isWifiInterface() {
                    let wifiCandidates = hhaddresses.filter({ $0.isCandidateAddress(bluetoothOnly: self.bluetoothOnly) && $0.isWifiInterface() })
                    if wifiCandidates.count > 0 {
                        chosenAddress = wifiCandidates.first!
                    }
                }
                
                DLog("BluepeerObject connectBlock: \(peer.displayName) has \(hhaddresses.count) addresses, chose \(chosenAddress.addressAndPortString) on interface \(chosenAddress.interfaceName)")
                let sockdata = chosenAddress.socketAsData()
                
                // TODO: when migrating Wifibooth, blueprint: make sure browserFoundPeer calls stopBrowsing()!
                // 1.1: don't stop browsing automatically, delegate must do that now
                //                    self.stopBrowsing() // stop browsing once user has done something. Destroys all HHService except this one!
                
                if let oldSocket = peer.socket {
                    DLog("**** BluepeerObject connectBlock: PEER ALREADY HAD SOCKET, DESTROYING...")
                    oldSocket.synchronouslySetDelegate(nil)
                    oldSocket.disconnect()
                    peer.socket = nil
                }
                
                peer.socket = GCDAsyncSocket.init(delegate: self, delegateQueue: self.socketQueue)
                peer.socket?.isIPv4PreferredOverIPv6 = false
                peer.state = .connecting
                try peer.socket?.connect(toAddress: sockdata, viaInterface: chosenAddress.interfaceName, withTimeout: 20.0)
            } catch {
                DLog("BluepeerObject: could not connect, ERROR: \(error)")
                peer.state = .notConnected
            }
        }
        
        self.announcePeer(peer: peer)
    }
    
    public func serviceDidNotResolve(_ service: HHService) {
        DLog("BluepeerObject: ERROR, service did not resolve: \(service.name)")
    }
}

extension HHAddressInfo {
    func isIPV6() -> Bool {
        let socketAddrData = Data.init(bytes: self.address, count: MemoryLayout<sockaddr>.size)
        var storage = sockaddr_storage()
        (socketAddrData as NSData).getBytes(&storage, length: MemoryLayout<sockaddr_storage>.size)
        if Int32(storage.ss_family) == AF_INET6 {
            return true
        } else {
            return false
        }
    }
    
    func isWifiInterface() -> Bool {
        return self.interfaceName == "en0"
    }
    
    func socketAsData() -> Data {
        var socketAddrData = Data.init(bytes: self.address, count: MemoryLayout<sockaddr>.size)
        var storage = sockaddr_storage()
        (socketAddrData as NSData).getBytes(&storage, length: MemoryLayout<sockaddr_storage>.size)
        if Int32(storage.ss_family) == AF_INET6 {
            socketAddrData = Data.init(bytes: self.address, count: MemoryLayout<sockaddr_in6>.size)
        }
        return socketAddrData
    }

    func isCandidateAddress(bluetoothOnly: Bool) -> Bool {
        if bluetoothOnly && self.isWifiInterface() {
            return false
        }
        if ProcessInfo().isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 10, minorVersion: 0, patchVersion: 0)) {
            // iOS 10: *require* IPv6 address!
            return self.isIPV6()
        } else {
            return true
        }
    }
    
    func IP() -> String? {
        let ipAndPort = self.addressAndPortString
        guard let lastColonIndex = ipAndPort.range(of: ":", options: .backwards)?.lowerBound else {
            DLog("ERROR: unexpected return of IP address with port")
            assert(false, "error")
            return nil
        }
        let ip = ipAndPort.substring(to: lastColonIndex)
        if ipAndPort.components(separatedBy: ":").count-1 > 1 {
            // ipv6 - looks like [00:22:22.....]:port
            return ip.substring(with: Range(uncheckedBounds: (lower: ip.index(ip.startIndex, offsetBy: 1), upper: ip.index(ip.endIndex, offsetBy: -1))))
        }
        return ip
    }
}


extension BluepeerObject : GCDAsyncSocketDelegate {
    
    public func socket(_ sock: GCDAsyncSocket, didAcceptNewSocket newSocket: GCDAsyncSocket) {
        
        if self.membershipAdminDelegate != nil {
            guard let connectedHost = newSocket.connectedHost else {
                DLog("BluepeerObject: ERROR, accepted newSocket has no connectedHost (no-op)")
                return
            }
            newSocket.delegate = self
            let newPeer = BPPeer.init()
            newPeer.state = .awaitingAuth
            newPeer.role = .client
            newPeer.socket = newSocket
            self.peers.append(newPeer) // always add as a new peer, even if it already exists. This might result in a dupe if we are browsing and advertising for same service. The original will get removed on receiving the name of other device, if it matches
            DLog("BluepeerObject: accepting new connection from \(connectedHost). Peers(n=\(self.peers.count)) after adding:")
            DLog(self.peers)
            
            // CONVENTION: CLIENT sends SERVER 32 bytes of its name -- UTF-8 string
            self.logDelegate?.didReadWrite("readName")
            newSocket.readData(toLength: 32, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_NAME.rawValue)
        } else {
            DLog("BluepeerObject: WARNING, ignoring connection attempt because I don't have a sessionDelegate assigned")
        }
    }
    
    public func socket(_ sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
        guard let peer = sock.peer else {
            DLog("BluepeerObject: WARNING, did not find peer in didConnectToHost, doing nothing")
            return
        }
        peer.state = .awaitingAuth
        DLog("BluepeerObject: got to state = awaitingAuth with \(sock.connectedHost), sending name then awaiting ACK ('0')")
        let strData = self.displayNameSanitized.data(using: String.Encoding.utf8)! as NSData
        // Other side is expecting to receive EXACTLY 32 bytes so pad to 32 bytes!
        let paddedStrData: NSMutableData = ("                                ".data(using: String.Encoding.utf8) as NSData?)?.mutableCopy() as! NSMutableData // that's 32 spaces :)
        paddedStrData.replaceBytes(in: NSMakeRange(0, strData.length), withBytes: strData.bytes)
        self.logDelegate?.didReadWrite("writeName")
        
        DLog("didConnect, writing name: \((paddedStrData as Data).hex)")
        sock.write(paddedStrData as Data, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_WRITING.rawValue)
        
        // now await auth
        self.logDelegate?.didReadWrite("waitToReadAuth")
        sock.readData(toLength: 1, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_AUTH.rawValue)
    }
    
    public func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Error?) {
        let matchingPeers = self.peers.filter({ $0.socket == sock})
        if matchingPeers.count != 1 {
            DLog("BluepeerObject socketDidDisconnect: WARNING expected to find 1 peer with this socket but found \(matchingPeers.count), calling peerConnectionAttemptFailed")
            sock.synchronouslySetDelegate(nil)
            self.dispatch_on_delegate_queue({
                self.membershipRosterDelegate?.peerConnectionAttemptFailed?(.unknown, peer: nil, isAuthRejection: false)
            })
            return
        }
        let peer = matchingPeers.first!
        DLog("BluepeerObject socketDidDisconnect: \(peer.displayName) @ \(peer.socket?.connectedHost) disconnected. Peers(n=\(self.peers.count)): \(self.peers)")
        let oldState = peer.state
        peer.state = .notConnected
        peer.keepaliveTimer?.invalidate()
        peer.keepaliveTimer = nil
        peer.socket = nil
        sock.synchronouslySetDelegate(nil)
        switch oldState {
        case .authenticated:
            self.dispatch_on_delegate_queue({
                self.membershipRosterDelegate?.peerDidDisconnect?(peer.role, peer: peer)
            })
        case .notConnected:
            assert(false, "ERROR: state is being tracked wrong")
        case .connecting, .awaitingAuth:
            self.dispatch_on_delegate_queue({
                self.membershipRosterDelegate?.peerConnectionAttemptFailed?(peer.role, peer: peer, isAuthRejection: oldState == .awaitingAuth)
            })
        }

        guard let lastService = peer.lastService, let hhaddresses = lastService.resolvedAddressInfo else {
            DLog("BluepeerObject socketDidDisconnect: not reannouncing, since .lastService.resolvedAddressInfo is nil")
            return
        }
        
        if hhaddresses.count > 0 {
            if abs(peer.lastReannounce.timeIntervalSinceNow) > 5.0 {
                peer.lastReannounce = Date.init()
                DLog("BluepeerObject socketDidDisconnect: re-announcing now!")
                self.announcePeer(peer: peer)
            } else {
                DLog("BluepeerObject socketDidDisconnect: not reannouncing, since TOO QUICK")
            }
        } else {
            DLog("BluepeerObject socketDidDisconnect: not reannouncing, since there are no addresses")
        }
    }
    
    fileprivate func disconnectSocket(socket: GCDAsyncSocket?, peer: BPPeer) {
        peer.state = .notConnected
        socket?.synchronouslySetDelegate(nil)
        socket?.disconnect()
        peer.socket = nil
    }
    
    public func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
        
//        DLog("socket reads: \(data.hex)")
        
        guard let peer = sock.peer else {
            DLog("BluepeerObject: WARNING, did not find peer in didReadData, doing nothing")
            return
        }
        self.scheduleNextKeepaliveTimer(peer)

        if tag == DataTag.tag_AUTH.rawValue {
            if data.count != 1 {
                assert(false, "ERROR: not right length of bytes")
                self.disconnectSocket(socket: sock, peer: peer)
                return
            }
            var ack: UInt8 = 1
            (data as NSData).getBytes(&ack, length: 1)
            if (ack != 0 || peer.state != .awaitingAuth) {
                assert(false, "ERROR: not the right ACK, or state was not .awaitingAuth as expected")
                self.disconnectSocket(socket: sock, peer: peer)
                return
            }
            peer.state = .authenticated // CLIENT becomes authenticated
            self.dispatch_on_delegate_queue({
                self.membershipRosterDelegate?.peerDidConnect?(peer.role, peer: peer)
            })
            self.logDelegate?.didReadWrite("peerState=connected (auth OK), readHeaderTerminator1")
            sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
            
        } else if tag == DataTag.tag_HEADER.rawValue {
            // first, strip the trailing headerTerminator
            let range = 0..<data.count-self.headerTerminator.count
            let dataWithoutTerminator = data.subdata(in: Range(range))
            if dataWithoutTerminator == self.keepAliveHeader {
                DLog("BluepeerObject: got keepalive")
                self.logDelegate?.didReadWrite("readKeepAlive from \(peer.displayName)")
                sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
            } else {
                // take the first 4 bytes and use them as UInt of length of data. read the next 4 bytes and discard for now, might use them as version code? in future
                
                var length: UInt = 0
                (dataWithoutTerminator as NSData).getBytes(&length, length: 4)
                // ignore bytes 4-8 for now
                DLog("BluepeerObject: got header, reading \(length) bytes...")
                self.logDelegate?.didReadWrite("readBodyAfterHeader")
                sock.readData(toLength: length, withTimeout: Timeouts.body.rawValue, tag: DataTag.tag_BODY.rawValue)
            }
            
        } else if tag == DataTag.tag_NAME.rawValue {
            
            var name = String.init(data: data, encoding: String.Encoding.utf8)
            if name == nil {
                name = "Unknown"
            }
            name = name!.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) // sender pads with spaces to 32 bytes
            peer.displayName = self.sanitizeCharsToDNSChars(str: name!) // probably unnecessary but need to be safe
            
            // we're the server. If we are advertising and browsing for the same serviceType, there might be a duplicate peer situation to take care of -- one created by browsing, one when socket was accepted. Remedy: kill old one, keep this one
            for existingPeer in self.peers.filter({ $0.displayName == peer.displayName && $0 != peer }) {
                if let indexOfPeer = self.peers.index(of: existingPeer) {
                    DLog("BluepeerObject: about to remove dupe peer \(self.peers[indexOfPeer].displayName) from index \(indexOfPeer), had socket: \(self.peers[indexOfPeer].socket != nil ? "ACTIVE" : "nil"). Peers(n=\(self.peers.count)) before removal:")
                    DLog(self.peers)
                    
                    self.peers.remove(at: indexOfPeer)
                }
                self.disconnectSocket(socket: existingPeer.socket, peer: existingPeer)
                peer.lastService?.endResolve()
                peer.lastService = nil // there's not really supposed to be a dnsService present here, this is paranoia
                peer.keepaliveTimer?.invalidate()
                peer.keepaliveTimer = nil
            }
            
            if let delegate = self.membershipAdminDelegate {
                self.dispatch_on_delegate_queue({
                    delegate.peerConnectionRequest?(peer, invitationHandler: { (inviteAccepted) in
                        if inviteAccepted && peer.state == .awaitingAuth && sock.isConnected == true {
                            peer.state = .authenticated // SERVER-local-peer becomes connected
                            // CONVENTION: SERVER sends CLIENT a single 0 to show connection has been accepted, since it isn't possible to send a header for a payload of size zero except here.
                            self.logDelegate?.didReadWrite("writeAuthAcceptance")
                            sock.write(Data.init(count: 1), withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_WRITING.rawValue)
                            DLog("... accepted (by my delegate)")
                            self.dispatch_on_delegate_queue({
                                self.membershipRosterDelegate?.peerDidConnect?(.client, peer: peer)
                            })
                            self.logDelegate?.didReadWrite("readHeaderTerminator2")
                            self.scheduleNextKeepaliveTimer(peer) // NEW in 1.1: if the two sides open up a connection but no one says anything, make sure it stays open
                            sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
                        } else {
                            self.logDelegate?.didReadWrite("writeAuthRejection!") // TODO: seen here when shouldn't be. Probably peer.state was something unexpected...?
                            self.disconnectSocket(socket: sock, peer: peer)
                            DLog("... rejected (by my delegate), or no longer connected")
                        }
                    })
                })
            }
            
        } else { // BODY case
            self.dispatch_on_delegate_queue({
                self.dataDelegate?.didReceiveData(data, fromPeer: peer)
            })
            self.logDelegate?.didReadWrite("readHeaderTerminator3-receiveData")
            sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
        }
    }
    
    public func socket(_ sock: GCDAsyncSocket, didReadPartialDataOfLength partialLength: UInt, tag: Int) {
        guard let peer = sock.peer else {
            return
        }
        self.scheduleNextKeepaliveTimer(peer)
    }
    
    public func socket(_ sock: GCDAsyncSocket, shouldTimeoutReadWithTag tag: Int, elapsed: TimeInterval, bytesDone length: UInt) -> TimeInterval {
        return self.calcTimeExtension(sock, tag: tag)
    }
    
    public func calcTimeExtension(_ sock: GCDAsyncSocket, tag: Int) -> TimeInterval {
        guard let peer = sock.peer else {
            return 0
        }
        
        let timeSinceLastData = abs(peer.lastReceivedData.timeIntervalSinceNow)
        if timeSinceLastData > (2.0 * Timeouts.keepAlive.rawValue) {
            // timeout!
            DLog("BluepeerObject: socket timed out waiting for read/write - data last seen \(timeSinceLastData). Tag: \(tag). Disconnecting.")
            sock.disconnect()
            return 0
        } else {
            // extend
            DLog("BluepeerObject: extending socket timeout by \(Timeouts.keepAlive.rawValue)s bc I saw data \(timeSinceLastData)s ago")
            return Timeouts.keepAlive.rawValue
        }
    }
}

extension BluepeerObject: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard self.bluetoothPeripheralManager != nil else {
            DLog("!!!!!! BluepeerObject bluetooth state change with no bluetoothPeripheralManager !!!!!")
            return
        }
        DLog("Bluetooth status: ")
        switch (self.bluetoothPeripheralManager.state) {
        case .unknown:
            DLog("Unknown")
            self.bluetoothState = .unknown
        case .resetting:
            DLog("Resetting")
            self.bluetoothState = .other
        case .unsupported:
            DLog("Unsupported")
            self.bluetoothState = .other
        case .unauthorized:
            DLog("Unauthorized")
            self.bluetoothState = .other
        case .poweredOff:
            DLog("PoweredOff")
            self.bluetoothState = .poweredOff
        case .poweredOn:
            DLog("PoweredOn")
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

extension Data {
    var hex: String {
        return self.map { b in String(format: "%02X", b) }.joined()
    }
}

extension Dictionary {
    mutating func merge(with a: Dictionary) {
        for (k,v) in a {
            self[k] = v
        }
    }
}
