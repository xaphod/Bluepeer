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
import xaphodObjCUtils
import DataCompression

// "Any" means can be both a client and a server. If accepting a new connection from another peer, that peer is deemed a client. If found an advertising .any peer, that peer is considered a server.
@objc public enum RoleType: Int, CustomStringConvertible {
    case unknown = 0
    case server = 1
    case client = 2
    case any = 3
    
    public var description: String {
        switch self {
        case .server: return "Server"
        case .client: return "Client"
        case .unknown: return "Unknown"
        case .any: return "Any"
        }
    }
    
    public static func roleFromString(_ roleStr: String?) -> RoleType {
        guard let roleStr = roleStr else {
            assert(false, "ERROR")
            return .unknown
        }
        switch roleStr {
            case "Server": return .server
            case "Client": return .client
            case "Unknown": return .unknown
            case "Any": return .any
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

@objc public enum BluepeerInterfaces: Int {
    case any = 0
    case infrastructureModeWifiOnly
    case notWifi
}


@objc public enum BPPeerState: Int, CustomStringConvertible {
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
    @objc open var displayName: String = "" // is same as HHService.name !
    @objc open var displayShortName: String { // doesn't have the "-0923" numbers at the end
        if displayName.count <= 5 {
            return displayName
        }
        let index = displayName.index(displayName.endIndex, offsetBy: -5)
        return String(displayName.prefix(upTo: index))
    }
    @objc open var role: RoleType = .unknown
    @objc open var state: BPPeerState = .notConnected
    @objc open var canConnect: Bool {
        return self.candidateAddresses.count > 0
    }
    @objc open var keepaliveTimer: Timer?
    @objc open var lastDataRead: Date = Date.init(timeIntervalSince1970: 0) // includes keepalives
    @objc open var lastDataKeepAliveWritten: Date = Date.init(timeIntervalSince1970: 0) // only keepalives
    @objc open var lastDataNonKeepAliveWritten: Date = Date.init(timeIntervalSince1970: 0) // no keepalives
    public typealias ConnectBlock = ()->Bool
    @objc open var connect: (ConnectBlock)? // false if no connection attempt will happen
    @objc open func disconnect() {
        socket?.disconnect()
    }
    @objc open var customData = [String:AnyHashable]() // store your own data here. When a browser finds an advertiser and creates a peer for it, this will be filled out with the advertiser's customData *even before any connection occurs*. Note that while you can store values that are AnyHashable, only Strings are used as values for advertiser->browser connections.
    weak var owner: BluepeerObject?

    var connectCount=0, disconnectCount=0, connectAttemptFailCount=0, connectAttemptFailAuthRejectCount=0, dataRecvCount=0, dataSendCount=0
    override open var description: String {
        var socketDesc = "nil"
        if let socket = self.socket {
            if let host = socket.connectedHost {
                socketDesc = host
            } else {
                socketDesc = "NOT connected"
            }
        }
        let lastDataWritten = max(self.lastDataNonKeepAliveWritten, self.lastDataKeepAliveWritten) // the most recent
        return "\n[\(displayName) is \(state) as \(role) on \(lastInterfaceName ?? "nil") with \(customData.count) customData keys. C:\(connectCount) D:\(disconnectCount) cFail:\(connectAttemptFailCount) cFailAuth:\(connectAttemptFailAuthRejectCount), Data In#:\(dataRecvCount) LastRecv: \(lastDataRead), LastWrite: \(lastDataWritten), Out#:\(dataSendCount). Socket: \(socketDesc), services#: \(services.count) (\(resolvedServices().count) resolved)]"
    }
    @objc open var isConnectedViaWifi: Bool {
        guard let interface = self.lastInterfaceName else {
            return false
        }
        return interface == BluepeerObject.iOS_wifi_interface
    }

    // fileprivates
    fileprivate var socket: GCDAsyncSocket?
    fileprivate var services = [HHService]()
    fileprivate func resolvedServices() -> [HHService] {
        return services.filter { $0.resolved == true }
    }
    fileprivate func pickedResolvedService() -> HHService? {
        // this function determines which of the resolved services is used
        return resolvedServices().last
    }
    fileprivate func destroyServices() {
        for service in services {
            service.delegate = nil
            service.endResolve()
        }
        services = [HHService]()
    }
    fileprivate var candidateAddresses: [HHAddressInfo] {
        guard let hhaddresses2 = self.pickedResolvedService()?.resolvedAddressInfo, hhaddresses2.count > 0 else {
            return []
        }
        var interfaces: BluepeerInterfaces = .any
        if let owner = self.owner {
            interfaces = owner.bluepeerInterfaces
        }
        return hhaddresses2.filter({ $0.isCandidateAddress(excludeWifi: interfaces == .notWifi, onlyWifi: interfaces == .infrastructureModeWifiOnly) })
    }

    fileprivate var lastInterfaceName: String?
    fileprivate var clientReceivedBytes: Int = 0
}

@objc public protocol BluepeerMembershipRosterDelegate {
    @objc optional func bluepeer(_ bluepeerObject: BluepeerObject, peerDidConnect peerRole: RoleType, peer: BPPeer)
    @objc optional func bluepeer(_ bluepeerObject: BluepeerObject, peerDidDisconnect peerRole: RoleType, peer: BPPeer, canConnectNow: Bool) // canConnectNow: true if this peer is still announce-able, ie. can now call connect() on it. Note, it is highly recommended to have a ~2 sec delay before calling connect() to avoid 100% CPU loops
    @objc optional func bluepeer(_ bluepeerObject: BluepeerObject, peerConnectionAttemptFailed peerRole: RoleType, peer: BPPeer?, isAuthRejection: Bool, canConnectNow: Bool) // canConnectNow: true if this peer is still announce-able, ie. can now call connect() on it. Note, it is highly recommended to have a ~2 sec delay before calling connect() to avoid 100% CPU loops
}

@objc public protocol BluepeerMembershipAdminDelegate {
    @objc optional func bluepeer(_ bluepeerObject: BluepeerObject, peerConnectionRequest peer: BPPeer, invitationHandler: @escaping (Bool) -> Void) // Someone's trying to connect to you. Earlier this was named: sessionConnectionRequest
    @objc optional func bluepeer(_ bluepeerObject: BluepeerObject, browserFindingPeer isNew: Bool) // There's someone out there with the same serviceType, which is now being queried for more details. This can occur as much as 2 seconds before browserFoundPeer(), so it's used to give you an early heads-up. If this peer has not been seen before, isNew is true.
    @objc optional func bluepeer(_ bluepeerObject: BluepeerObject, browserFindingPeerFailed unused: Bool) // balances the previous call. Use to cancel UI like progress indicator etc.
    @objc optional func bluepeer(_ bluepeerObject: BluepeerObject, browserFoundPeer role: RoleType, peer: BPPeer) // You found someone to connect to. The peer has connect() that can be executed, and your .customData too. This can be called more than once for the same peer.
    @objc optional func bluepeer(_ bluepeerObject: BluepeerObject, browserLostPeer role: RoleType, peer: BPPeer)
}

@objc public protocol BluepeerDataDelegate {
    @objc optional func bluepeer(_ bluepeerObject: BluepeerObject, receivingData bytesReceived: Int, totalBytes: Int, peer: BPPeer) // the values of 0 and 100% are guaranteed prior to didReceiveData
    @objc func bluepeer(_ bluepeerObject: BluepeerObject, didReceiveData data: Data, peer: BPPeer)
}


@objc public protocol BluepeerLoggingDelegate {
    @objc func logString(_ message: String)
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


@objc open class BluepeerObject: NSObject {
    static let kDNSServiceInterfaceIndexP2PSwift = UInt32.max-2
    static let iOS_wifi_interface = "en0"
    
    @objc var delegateQueue: DispatchQueue?
    @objc var serverSocket: GCDAsyncSocket?
    @objc var publisher: HHServicePublisher?
    @objc var browser: HHServiceBrowser?
    fileprivate var bluepeerInterfaces: BluepeerInterfaces = .any
    open var advertisingRole: RoleType?
    @objc var advertisingCustomData = [String:String]()
    @objc open var browsing: Bool = false
    var onLastBackground: (advertising: RoleType?, browsing: Bool) = (nil, false)
    @objc open var serviceType: String = ""
    @objc var serverPort: UInt16 = 0
    @objc var versionString: String = "unknown"
    @objc open var displayNameSanitized: String = ""
    @objc var appIsInBackground = false
    
    @objc weak open var membershipAdminDelegate: BluepeerMembershipAdminDelegate?
    @objc weak open var membershipRosterDelegate: BluepeerMembershipRosterDelegate?
    @objc weak open var dataDelegate: BluepeerDataDelegate?
    @objc weak open var logDelegate: BluepeerLoggingDelegate? {
        didSet {
            fileLogDelegate = logDelegate
        }
    }
    @objc open var peers = [BPPeer]() // does not include self
    @objc open var bluetoothState : BluetoothState = .unknown
    @objc var bluetoothPeripheralManager: CBPeripheralManager!
    @objc open var bluetoothBlock: ((_ bluetoothState: BluetoothState) -> Void)?
    @objc open var disconnectOnBackground: Bool = false
    let headerTerminator: Data = "\r\n\r\n".data(using: String.Encoding.utf8)! // same as HTTP. But header content here is just a number, representing the byte count of the incoming nsdata.
    let keepAliveHeader: Data = "0 ! 0 ! 0 ! 0 ! 0 ! 0 ! 0 ! ".data(using: String.Encoding.utf8)! // A special header kept to avoid timeouts
    let socketQueue = DispatchQueue(label: "xaphod.bluepeer.socketQueue", attributes: [])
    @objc var browsingWorkaroundRestarts = 0
    
    /// nil   : no compression
    /// ZLIB  : Fast with a very solid compression rate. There is a reason it is used everywhere.
    /// LZFSE : Apples proprietary compression algorithm. Claims to compress as good as ZLIB but 2 to 3 times faster.
    /// LZMA  : Horribly slow. Compression as well as decompression. Normally you will regret choosing LZMA.
    /// LZ4   : Fast, but depending on the data the compression rate can be really bad. Which is often the case.
    open var compressionAlgorithm: Data.CompressionAlgorithm? = .lzfse
    @objc open func turnOffCompression() { self.compressionAlgorithm = nil }
    
    enum DataTag: Int {
        case tag_HEADER = -1
//        case tag_BODY = -2  -- no longer used: negative tag values are conventional, positive tag values indicate number of bytes expected to read
        case tag_WRITING = -3
        case tag_AUTH = -4
        case tag_NAME = -5
        case tag_WRITINGKEEPALIVE = -6 // new in 1.4.0
    }
    
    enum Timeouts: Double {
        case header = 40
        case body = 90
        case keepAlive = 16
    }
    
    fileprivate var fileLogDelegate: BluepeerLoggingDelegate?
    
    func dlog(_ items: CustomStringConvertible...) {
        var willLog = false
        #if DEBUG
        willLog = true
        #endif
        if let _ = fileLogDelegate {
            willLog = true
        }
        guard willLog else { return }

        var str = ""
        for item in items {
            str += item.description
        }
        let serviceType = self.serviceType.replacingOccurrences(of: "_xd-", with: "").replacingOccurrences(of: "._tcp", with: "")
        
        if let del = fileLogDelegate {
            del.logString("Bluepeer \(serviceType) " + str)
        } else {
            let formatter = DateFormatter.init()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS"
            let out = formatter.string(from: Date.init()) + " - Bluepeer \(serviceType) - " + str
            print(out)
        }
    }
    
    // if queue isn't given, main queue is used
    @objc public init?(serviceType: String, displayName:String?, queue:DispatchQueue?, serverPort: UInt16, interfaces: BluepeerInterfaces, logDelegate: BluepeerLoggingDelegate? = nil, bluetoothBlock: ((_ bluetoothState: BluetoothState)->Void)?) {
        
        super.init()
        fileLogDelegate = logDelegate
        
        if #available(iOS 13.1, *) {
            dlog("CBManager.authorization = \(CBManager.authorization.debugDescription)")
        }

        // serviceType must be 1-15 chars, only a-z0-9 and hyphen, eg "xd-blueprint"
        if serviceType.count > 15 {
            assert(false, "ERROR: service name is too long")
            return nil
        }
        self.serviceType = "_" + self.sanitizeCharsToDNSChars(str: serviceType) + "._tcp"
        
        self.serverPort = serverPort
        self.delegateQueue = queue
        self.bluepeerInterfaces = interfaces
        
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
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        if #available(iOS 8.2, *) {
            NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: NSNotification.Name.NSExtensionHostDidEnterBackground, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: NSNotification.Name.NSExtensionHostWillEnterForeground, object: nil)
        } 
        
        dlog("Initialized. Name: \(self.displayNameSanitized)")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        self.killAllKeepaliveTimers() // probably moot: won't start deiniting until all timers are dead, because they have a strong ref to self
        self.disconnectSession()
        self.stopBrowsing()
        self.stopAdvertising()
        dlog("DEINIT FINISH")
    }
    
    override open var description: String {
        let formatter = DateFormatter.init()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        var retval = ""
        for peer in self.peers {
            retval += peer.description + "\n"
        }
        return retval
    }
    
    // Note: if I disconnect, then my delegate is expected to reconnect if needed.
    @objc func didEnterBackground() {
        self.appIsInBackground = true
        self.onLastBackground = (self.advertisingRole, self.browsing)
        stopBrowsing()
        stopAdvertising()
        if disconnectOnBackground {
            disconnectSession()
            dlog("didEnterBackground - stopped browsing & advertising, and disconnected session")
        } else {
            dlog("didEnterBackground - stopped browsing & advertising")
        }
    }
    
    @objc func willEnterForeground() {
        dlog("willEnterForeground")
        self.appIsInBackground = false
        if let role = self.onLastBackground.advertising {
            dlog("willEnterForeground, startAdvertising")
            startAdvertising(role, customData: self.advertisingCustomData)
        }
        if self.onLastBackground.browsing {
            dlog("willEnterForeground, startBrowsing")
            startBrowsing()
        }
    }
    
    func sanitizeCharsToDNSChars(str: String) -> String {
        let acceptableChars = CharacterSet.init(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz1234567890-")
        return String(str.filter({ $0 != "'"}).map { (char: Character) in
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
        for c in retval {
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
        dlog("sanitized \(str) to \(retval)")
        return retval
    }
    
    @objc open func disconnectSession() {
        // don't close serverSocket: expectation is that only stopAdvertising does this
        // loop through peers, disconenct all sockets
        for peer in self.peers {
            dlog(" disconnectSession: disconnecting \(peer.displayName)")
            peer.socket?.synchronouslySetDelegate(nil) // we don't want to run our disconnection logic below
            peer.socket?.disconnect()
            peer.socket = nil
            peer.destroyServices()
            peer.state = .notConnected
            peer.keepaliveTimer?.invalidate()
            peer.keepaliveTimer = nil
        }
        self.peers = [] // remove all peers!
    }
    
    @objc open func connectedPeers(_ role: RoleType) -> [BPPeer] {
        return self.peers.filter({ $0.role == role && $0.state == .authenticated })
    }
    
    @objc open func connectedPeers() -> [BPPeer] {
        return self.peers.filter({ $0.state == .authenticated })
    }
    
    // specify customData if this is needed for browser to decide whether to connect or not. Each key and value should be less than 255 bytes, and the total should be less than 1300 bytes.
    @objc open func startAdvertising(_ role: RoleType, customData: [String:String]) {
        if let _ = self.advertisingRole {
            dlog("Already advertising (no-op)")
            return
        }

        dlog("starting advertising using port \(serverPort)")

        // type must be like: _myexampleservice._tcp  (no trailing .)
        // txtData, from http://www.zeroconf.org/rendezvous/txtrecords.html: Using TXT records larger than 1300 bytes is NOT RECOMMENDED at this time. The format of the data within a DNS TXT record is zero or more strings, packed together in memory without any intervening gaps or padding bytes for word alignment. The format of each constituent string within the DNS TXT record is a single length byte, followed by 0-255 bytes of text data.
    
        // Could use the NSNetService version of this (TXTDATA maker), it'd be easier :)
        var swiftdict: [String:String] = ["role":role.description, "comp":"1"] // 1.3.0: added compression flag to advertising/browsing, to make sure old clients cannot connect to new ones due to differing compression algorithms
        self.advertisingCustomData = customData
        swiftdict.merge(with: customData)
        
        let cfdata: Unmanaged<CFData>? = CFNetServiceCreateTXTDataWithDictionary(kCFAllocatorDefault, swiftdict as CFDictionary)
        guard let txtdata = cfdata?.takeUnretainedValue() else {
            dlog("ERROR could not create TXTDATA")
            return
        }
        self.publisher = HHServicePublisher.init(name: self.displayNameSanitized, type: self.serviceType, domain: "local.", txtData: txtdata as Data, port: UInt(serverPort))
        self.publisher?.mainDispatchQueue = socketQueue
        
        guard let publisher = self.publisher else {
            dlog("could not create publisher")
            return
        }
        publisher.delegate = self
        var starting: Bool
        
        switch self.bluepeerInterfaces {
        case .any:
            starting = publisher.beginPublish()
            break
        case .notWifi:
            starting = publisher.beginPublishOverBluetoothOnly()
            break
        case .infrastructureModeWifiOnly:
            starting = publisher.beginPublish(UInt32(kDNSServiceInterfaceIndexAny), includeP2P: false)
            break
        }
        
        if !starting {
            dlog("ERROR could not start advertising")
            self.publisher = nil
            self.advertisingRole = nil
            return
        }
        // serverSocket is created in didPublish delegate (from HHServicePublisherDelegate) below
        self.advertisingRole = role
    }
    
    @objc open func stopAdvertising(leaveServerSocketAlone: Bool = false) {
        if let _ = self.advertisingRole {
            if let publisher = self.publisher {
                publisher.endPublish()
            } else {
                dlog("WARNING: publisher is MIA while advertising set true!")
            }
            dlog("advertising stopped")
        } else {
            dlog("no advertising to stop (no-op)")
        }
        self.publisher = nil
        self.advertisingRole = nil
        if leaveServerSocketAlone == false {
            self.destroyServerSocket()
        }
    }
    
    fileprivate func createServerSocket() -> Bool {
        self.serverSocket = GCDAsyncSocket.init(delegate: self, delegateQueue: socketQueue)
        self.serverSocket?.isIPv4PreferredOverIPv6 = false
        guard let serverSocket = self.serverSocket else {
            dlog("ERROR - Could not create serverSocket")
            return false
        }
        
        do {
            try serverSocket.accept(onPort: serverPort)
        } catch {
            dlog("ERROR accepting on serverSocket")
            return false
        }

        dlog("Created serverSocket, is accepting on \(serverPort)")
        return true
    }
    
    fileprivate func destroyServerSocket() {
        if let socket = self.serverSocket {
            socket.synchronouslySetDelegate(nil)
            socket.disconnect()
            self.serverSocket = nil
            dlog("Destroyed serverSocket")
        }
    }
    
    @objc open func startBrowsing() {
        if self.browsing == true {
            dlog("Already browsing (no-op)")
            return
        }

        self.browser = HHServiceBrowser.init(type: self.serviceType, domain: "local.")
        self.browser?.mainDispatchQueue = socketQueue
        guard let browser = self.browser else {
            dlog("ERROR, could not create browser")
            return
        }
        browser.delegate = self
        
        switch self.bluepeerInterfaces {
        case .any:
            self.browsing = browser.beginBrowse()
            break
        case .notWifi:
            self.browsing = browser.beginBrowseOverBluetoothOnly()
            break
        case .infrastructureModeWifiOnly:
            self.browsing = browser.beginBrowse(UInt32(kDNSServiceInterfaceIndexAny), includeP2P: false)
            break
        }

        dlog("now browsing")
    }
    
    @objc open func stopBrowsing() {
        if (self.browsing) {
            if self.browser == nil {
                dlog("WARNING, browser is MIA while browsing set true! ")
            } else {
                self.browser!.endBrowse()
                dlog("browsing stopped")
            }
        } else {
            dlog("no browsing to stop")
        }
        self.browser = nil
        self.browsing = false
        for peer in self.peers {
            peer.destroyServices()
        }
    }
    
    @objc open func sendData(_ datas: [Data], toPeers:[BPPeer]) throws {
        for data in datas {
            for peer in toPeers {
                self.sendDataInternal(peer, data: data)
            }
        }
    }
    
    @objc open func sendData(_ datas: [Data], toRole: RoleType) throws {
        let targetPeers: [BPPeer] = peers.filter({
            if toRole != .any {
                return $0.role == toRole && $0.state == .authenticated
            } else {
                return $0.state == .authenticated
            }
        })
    
        for data in datas {
            if data.count == 0 {
                continue
            }
            for peer in targetPeers {
                self.sendDataInternal(peer, data: data)
            }
        }
    }

    func sendDataInternal(_ peer: BPPeer, data: Data) {
        // send header first. Then separator. Then send body.
        // length: send as 4-byte, then 4 bytes of unused 0s for now. assumes endianness doesn't change between platforms, ie 23 00 00 00 not 00 00 00 23
        
        // compress that data
        
        var dataToSend: Data
        var ratio: Double = 100.0
        var timeToCompress: Double = 0.0
        if let algorithm = self.compressionAlgorithm {
            let compressionStart = Date.init()
            guard let compressedData = data.compress(withAlgorithm: algorithm) else {
                assert(false)
                return
            }
            timeToCompress = abs(compressionStart.timeIntervalSinceNow)
            ratio = Double(compressedData.count) / Double(data.count) * 100.0
            dataToSend = compressedData
        } else {
            dataToSend = data
        }
        var length: UInt = UInt(dataToSend.count)
        let senddata = NSMutableData.init(bytes: &length, length: 4)
        let unused4bytesdata = NSMutableData.init(length: 4)!
        senddata.append(unused4bytesdata as Data)
        senddata.append(self.headerTerminator)
        senddata.append(dataToSend)
        dlog("sending \(senddata.length) bytes to \(peer.displayName): \(data.count) bytes compressed to \(dataToSend.count) bytes (\(ratio)%) in \(timeToCompress)s")

        
//        DLog("sendDataInternal writes: \((senddata as Data).hex), payload part: \(data.hex)")
        peer.dataSendCount += 1
        peer.socket?.write(senddata as Data, withTimeout: Timeouts.body.rawValue, tag: DataTag.tag_WRITING.rawValue)
    }
    
    func scheduleNextKeepaliveTimer(_ peer: BPPeer) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if peer.state != .authenticated || peer.socket == nil {
                return
            }

            peer.dataRecvCount += 1
            if peer.dataRecvCount + 1 == Int.max {
                peer.dataRecvCount = 0
            }

            if peer.keepaliveTimer?.isValid == true {
                return
            }

            let delay: TimeInterval = Timeouts.keepAlive.rawValue - 5 - (Double(arc4random_uniform(5000)) / Double(1000)) // keepAlive.rawValue - 5 - (up to 5)
            self.dlog("keepalive INITIAL SCHEDULING for \(peer.displayName) in \(delay)s")
            peer.keepaliveTimer = Timer.scheduledTimer(timeInterval: delay, target: self, selector: #selector(self.keepAliveTimerFired), userInfo: ["peer":peer], repeats: true)
        }
    }
    
    @objc func keepAliveTimerFired(_ timer: Timer) {
        guard let ui = timer.userInfo as? Dictionary<String, AnyObject> else {
            assert(false, "ERROR")
            timer.invalidate()
            return
        }
        guard let peer = ui["peer"] as? BPPeer else {
            dlog("keepAlive timer didn't find a peer, invalidating timer")
            timer.invalidate()
            return
        }
        if peer.state != .authenticated || peer.socket == nil {
            dlog("keepAlive timer finds peer isn't authenticated(connected), invalidating timer")
            timer.invalidate()
            peer.keepaliveTimer = nil
            return
        }
        
        // New in 1.4.0: send keepalives OR real data sends, not both at same time
        let timeKeepAlives = abs(peer.lastDataKeepAliveWritten.timeIntervalSinceNow)
        let timeNotKeepAlives = abs(peer.lastDataNonKeepAliveWritten.timeIntervalSinceNow)
        assert(Thread.current.isMainThread)
        guard timeNotKeepAlives > Timeouts.keepAlive.rawValue / 2.0 else {
            dlog("keepAlive timer no-op as data was recently sent: timeKeepAlive=\(timeKeepAlives), timeNotKeepAlive=\(timeNotKeepAlives)")
            return
        }
        var senddata = NSData.init(data: self.keepAliveHeader) as Data
        senddata.append(self.headerTerminator)
        dlog("writeKeepAlive to \(peer.displayName)")
        peer.socket?.write(senddata, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_WRITINGKEEPALIVE.rawValue)
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
    
    @objc open func getBrowser(_ completionBlock: @escaping (Bool) -> ()) -> UIViewController? {
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
    public func serviceDidPublish(_ servicePublisher: HHServicePublisher) {
        // create serverSocket
        if let socket = self.serverSocket {
            dlog("serviceDidPublish: USING EXISTING SERVERSOCKET \(socket)")
        } else {
            if self.createServerSocket() == false {
                return
            }
        }
        
        dlog("now advertising for service \(serviceType)")
    }
    
    public func serviceDidNotPublish(_ servicePublisher: HHServicePublisher) {
        self.advertisingRole = nil
        dlog("ERROR: serviceDidNotPublish")
    }
}

extension BluepeerObject : HHServiceBrowserDelegate {
    public func serviceBrowser(_ serviceBrowser: HHServiceBrowser, didFind service: HHService, moreComing: Bool) {
        if self.browsing == false {
            return
        }
        if self.displayNameSanitized == service.name { // names are made unique by having random numbers appended
            dlog("found my own published service, ignoring...")
            return
        }

        if service.type == self.serviceType {
            dlog("didFindService \(service.name), moreComing: \(moreComing)")
            service.delegate = self
            
            // if this peer exists, then add this as another address(es), otherwise add now
            var peer = self.peers.filter({ $0.displayName == service.name }).first
            
            if let peer = peer {
                dlog("didFind: added new unresolved service to peer \(peer.displayName)")
                peer.services.append(service)
                self.dispatch_on_delegate_queue({
                    self.membershipAdminDelegate?.bluepeer?(self, browserFindingPeer: false)
                })
            } else {
                peer = BPPeer.init()
                guard let peer = peer else { return }
                peer.owner = self
                peer.displayName = service.name
                peer.services.append(service)
                self.peers.append(peer)
                dlog("didFind: created new peer \(peer.displayName). Peers(n=\(self.peers.count)) after adding")
                self.dispatch_on_delegate_queue({
                    self.membershipAdminDelegate?.bluepeer?(self, browserFindingPeer: true)
                })
            }
            
            let prots = UInt32(kDNSServiceProtocol_IPv4) | UInt32(kDNSServiceProtocol_IPv6)
            switch self.bluepeerInterfaces {
            case .any:
                service.beginResolve(UInt32(kDNSServiceInterfaceIndexAny), includeP2P: true, addressLookupProtocols: prots)
                break
            case .notWifi:
                service.beginResolve(BluepeerObject.kDNSServiceInterfaceIndexP2PSwift, includeP2P: true, addressLookupProtocols: prots)
                break
            case .infrastructureModeWifiOnly:
                service.beginResolve(UInt32(kDNSServiceInterfaceIndexAny), includeP2P: false, addressLookupProtocols: prots)
                break
            }
        }
    }
    
    public func serviceBrowser(_ serviceBrowser: HHServiceBrowser, didRemove service: HHService, moreComing: Bool) {
        let matchingPeers = self.peers.filter({ $0.displayName == service.name })
        if matchingPeers.count == 0 {
            dlog("didRemoveService for service.name \(service.name) -- IGNORING because no peer found")
            return
        }
        for peer in matchingPeers {
            // if found exact service, then nil it out to prevent more connection attempts
            if let serviceIndex = peer.services.firstIndex(of: service) {
                let previousResolvedServiceCount = peer.resolvedServices().count
                dlog("didRemoveService - REMOVING SERVICE from \(peer.displayName)")
                peer.services.remove(at: serviceIndex)
                
                if peer.resolvedServices().count == 0 && previousResolvedServiceCount > 0 {
                    dlog("didRemoveService - that was the LAST resolved service so calling browserLostPeer for \(peer.displayName)")
                    self.dispatch_on_delegate_queue({
                        self.membershipAdminDelegate?.bluepeer?(self, browserLostPeer: peer.role, peer: peer)
                    })
                }
            } else {
                dlog("didRemoveService - \(peer.displayName) has no matching service (no-op)")
            }
        }
    }
}

extension BluepeerObject : HHServiceDelegate {
    public func serviceDidResolve(_ service: HHService, moreComing: Bool) {
        func cleanup() {
            self.dispatch_on_delegate_queue({
                self.membershipAdminDelegate?.bluepeer?(self, browserFindingPeerFailed: false)
            })
        }
        
        if self.browsing == false {
            return
        }
        
        guard let txtdata = service.txtData else {
            dlog("serviceDidResolve IGNORING service because no txtData found")
            cleanup()
            return
        }
        guard let hhaddresses: [HHAddressInfo] = service.resolvedAddressInfo, hhaddresses.count > 0 else {
            dlog("serviceDidResolve IGNORING service because could not get resolvedAddressInfo")
            cleanup()
            return
        }
        
        let cfdict: Unmanaged<CFDictionary>? = CFNetServiceCreateDictionaryWithTXTData(kCFAllocatorDefault, txtdata as CFData)
        guard let _ = cfdict else {
            dlog("serviceDidResolve IGNORING service because txtData was invalid")
            cleanup()
            return
        }
        let dict: NSDictionary = cfdict!.takeUnretainedValue()
        guard let rD = dict["role"] as? Data,
            let roleStr = String.init(data: rD, encoding: String.Encoding.utf8) else {
            dlog("serviceDidResolve IGNORING service because role was missing")
            cleanup()
            return
        }
        let role = RoleType.roleFromString(roleStr)
        switch role {
        case .unknown:
            assert(false, "Expecting a role that isn't unknown here")
            cleanup()
            return
        default:
            break
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
            dlog("serviceDidResolve FAILED, expected 1 peer but found \(matchingPeers.count)")
            assert(false)
            cleanup()
            return
        }
        let peer = matchingPeers.first!
        peer.role = role
        peer.customData = customData
        dlog("serviceDidResolve for \(peer.displayName) - addresses \(hhaddresses.count), peer.role: \(role), peer.state: \(peer.state), #customData:\(customData.count)")
        
        // if has insufficient version, don't announce it
        guard let compStr = customData["comp"], compStr == "1" else {
            dlog("serviceDidResolve: IGNORING THIS PEER, IT IS TOO OLD - DOES NOT SUPPORT CORRECT COMPRESSION ALGORITHM")
            cleanup()
            return
        }
        
        let candidates = hhaddresses.filter({ $0.isCandidateAddress(excludeWifi: self.bluepeerInterfaces == .notWifi, onlyWifi: self.bluepeerInterfaces == .infrastructureModeWifiOnly) })
        if peer.state != .notConnected {
            dlog("... has state!=notConnected, so no-op")
            return
        } else if candidates.count == 0 {
            dlog("... no candidates out of \(hhaddresses.count) addresses. moreComing = \(moreComing)")
            if hhaddresses.count > 1 && !moreComing && self.bluepeerInterfaces == .notWifi {
                if (self.browsingWorkaroundRestarts >= 3) {
                    dlog(" *** workarounds exhausted! falling back to not bluetoothOnly")
                    self.browsingWorkaroundRestarts = 0
                    self.bluepeerInterfaces = .any
                    let secondaryCandidates = hhaddresses.filter({ $0.isCandidateAddress(excludeWifi: self.bluepeerInterfaces == .notWifi, onlyWifi: self.bluepeerInterfaces == .infrastructureModeWifiOnly) })
                    if (secondaryCandidates.count <= 0) {
                        dlog("... STILL no candidates. Bummer.")
                        return
                    }
                } else {
                    self.browsingWorkaroundRestarts += 1
                    dlog(" *** workaround for BT radio connection delay: restarting browsing, \(self.browsingWorkaroundRestarts) of 3")
                    self.stopBrowsing()
                    if let indexOfPeer = self.peers.firstIndex(of: peer) {
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

        peer.connect = { [weak self] in
            guard let self = self else { return false }
            do {
                // pick the address to connect to INSIDE the block, because more addresses may have been added between announcement and inviteBlock being executed
                let candidateAddresses = peer.candidateAddresses
                guard candidateAddresses.count > 0 else {
                    self.dlog("connect: \(peer.displayName) has no candidates, BAILING")
                    return false
                }

                // We have N candidateAddresses from 1 resolved service, which should we pick?
                // if we tried to connect to one recently and failed, and there's another one, pick the other one
                var interimAddress: HHAddressInfo?
                if let lastInterfaceName = peer.lastInterfaceName, candidateAddresses.count > 1 {
                    let otherAddresses = candidateAddresses.filter { $0.interfaceName != lastInterfaceName }
                    if otherAddresses.count > 0 {
                        interimAddress = otherAddresses.first!
                        self.dlog("connect: \(peer.displayName) trying a different interface than last attempt. Now trying: \(interimAddress!.interfaceName)")
                    }
                }
                
                var chosenAddress = candidateAddresses.first!
                if let interimAddress = interimAddress {
                    // first priority is not always trying to reconnect on the same interface when >1 is available
                    chosenAddress = interimAddress
                } else {
                    // second priority is if we can use wifi, then do so
                    if self.bluepeerInterfaces != .notWifi && !chosenAddress.isWifiInterface() {
                        let wifiCandidates = candidateAddresses.filter({ $0.isWifiInterface() })
                        if wifiCandidates.count > 0 {
                            chosenAddress = wifiCandidates.first!
                        }
                    }
                }
                
                peer.lastInterfaceName = chosenAddress.interfaceName
                self.dlog("connect: \(peer.displayName) has \(peer.services.count) svcs (\(peer.resolvedServices().count) resolved); chose \(chosenAddress.addressAndPortString) on interface \(chosenAddress.interfaceName)")
                let sockdata = chosenAddress.socketAsData()
                
                if let oldSocket = peer.socket {
                    self.dlog("**** connect: PEER ALREADY HAD SOCKET, DESTROYING...")
                    oldSocket.synchronouslySetDelegate(nil)
                    oldSocket.disconnect()
                    peer.socket = nil
                }
                
                peer.socket = GCDAsyncSocket.init(delegate: self, delegateQueue: self.socketQueue)
                peer.socket?.isIPv4PreferredOverIPv6 = false
                peer.state = .connecting
                try peer.socket?.connect(toAddress: sockdata, withTimeout: 10.0)
//                try peer.socket?.connect(toAddress: sockdata, viaInterface: chosenAddress.interfaceName, withTimeout: 10.0)
                return true
            } catch {
                self.dlog("could not connect, ERROR: \(error)")
                peer.state = .notConnected
                return false
            }
        }
        
        guard let delegate = self.membershipAdminDelegate else {
            dlog("announcePeer: WARNING, no-op because membershipAdminDelegate is not set")
            return
        }
        
        if self.appIsInBackground == false {
            dlog("announcePeer: announcing now with browserFoundPeer - call peer.connect() to connect")
            self.dispatch_on_delegate_queue({
                delegate.bluepeer?(self, browserFoundPeer: peer.role, peer: peer)
            })
        } else {
            dlog("announcePeer: app is in BACKGROUND, no-op!")
        }
    }
    
    public func serviceDidNotResolve(_ service: HHService) {
        dlog("****** ERROR, service did not resolve: \(service.name) *******")
        self.dispatch_on_delegate_queue({
            self.membershipAdminDelegate?.bluepeer?(self, browserFindingPeerFailed: false)
        })
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
        return self.interfaceName == BluepeerObject.iOS_wifi_interface
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

    func isCandidateAddress(excludeWifi: Bool, onlyWifi: Bool) -> Bool {
        if excludeWifi && self.isWifiInterface() {
            return false
        }
        if onlyWifi && !self.isWifiInterface() {
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
            assert(false, "error")
            return nil
        }
        let ip = String(ipAndPort[..<lastColonIndex])
        if ipAndPort.components(separatedBy: ":").count-1 > 1 {
            // ipv6 - looks like [00:22:22.....]:port
            let start = ip.index(ip.startIndex, offsetBy: 1)
            let end = ip.index(ip.endIndex, offsetBy: -1)
            return String(ip[start ..< end])
        }
        return ip
    }
}


extension BluepeerObject : GCDAsyncSocketDelegate {
    
    public func socket(_ sock: GCDAsyncSocket, didAcceptNewSocket newSocket: GCDAsyncSocket) {
        
        if self.membershipAdminDelegate != nil {
            guard let connectedHost = newSocket.connectedHost, let localhost = newSocket.localHost else {
                dlog("ERROR, accepted newSocket has no connectedHost (no-op)")
                return
            }
            newSocket.delegate = self
            let newPeer = BPPeer.init()
            newPeer.owner = self
            newPeer.state = .awaitingAuth
            newPeer.role = .client
            newPeer.socket = newSocket
            newPeer.lastInterfaceName = XaphodUtils.interfaceName(ofLocalIpAddress: localhost)
            
            self.peers.append(newPeer) // always add as a new peer, even if it already exists. This might result in a dupe if we are browsing and advertising for same service. The original will get removed on receiving the name of other device, if it matches
            dlog("accepting new connection from \(connectedHost) on \(String(describing: newPeer.lastInterfaceName)). Peers(n=\(self.peers.count)) after adding")
            
            // CONVENTION: CLIENT sends SERVER 32 bytes of its name -- UTF-8 string
            newSocket.readData(toLength: 32, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_NAME.rawValue)
        } else {
            dlog("WARNING, ignoring connection attempt because I don't have a membershipAdminDelegate assigned")
        }
    }
    
    public func socket(_ sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
        guard let peer = sock.peer else {
            dlog("WARNING, did not find peer in didConnectToHost, doing nothing")
            return
        }
        peer.state = .awaitingAuth
        dlog("got to state = awaitingAuth with \(String(describing: sock.connectedHost)), sending name then awaiting ACK ('0')")
        let strData = self.displayNameSanitized.data(using: String.Encoding.utf8)! as NSData
        // Other side is expecting to receive EXACTLY 32 bytes so pad to 32 bytes!
        let paddedStrData: NSMutableData = ("                                ".data(using: String.Encoding.utf8) as NSData?)?.mutableCopy() as! NSMutableData // that's 32 spaces :)
        paddedStrData.replaceBytes(in: NSMakeRange(0, strData.length), withBytes: strData.bytes)
        
        dlog("didConnect to \(String(describing: sock.connectedHost)), writing name: \((paddedStrData as Data).hex)")
        sock.write(paddedStrData as Data, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_WRITING.rawValue)
        
        // now await auth
        dlog("waiting to read Auth from \(String(describing: sock.connectedHost))...")
        sock.readData(toLength: 1, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_AUTH.rawValue)
    }
    
    public func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Error?) {
        let matchingPeers = self.peers.filter({ $0.socket == sock})
        if matchingPeers.count != 1 {
            dlog(" socketDidDisconnect: WARNING expected to find 1 peer with this socket but found \(matchingPeers.count), calling peerConnectionAttemptFailed.")
            sock.synchronouslySetDelegate(nil)
            self.dispatch_on_delegate_queue({
                self.membershipRosterDelegate?.bluepeer?(self, peerConnectionAttemptFailed: .unknown, peer: nil, isAuthRejection: false, canConnectNow: false)
            })
            return
        }
        let peer = matchingPeers.first!
        dlog(" socketDidDisconnect: \(peer.displayName) disconnected. Peers(n=\(self.peers.count))")
        let oldState = peer.state
        peer.state = .notConnected
        peer.keepaliveTimer?.invalidate()
        peer.keepaliveTimer = nil
        peer.socket = nil
        sock.synchronouslySetDelegate(nil)
        
        switch oldState {
        case .authenticated:
            peer.disconnectCount += 1
            self.dispatch_on_delegate_queue({
                self.membershipRosterDelegate?.bluepeer?(self, peerDidDisconnect: peer.role, peer: peer, canConnectNow: peer.canConnect)
            })
            break
        case .notConnected:
            break
        case .connecting, .awaitingAuth:
            peer.connectAttemptFailCount += 1
            if oldState == .awaitingAuth {
                peer.connectAttemptFailAuthRejectCount += 1
            }
            self.dispatch_on_delegate_queue({
                self.membershipRosterDelegate?.bluepeer?(self, peerConnectionAttemptFailed: peer.role, peer: peer, isAuthRejection: oldState == .awaitingAuth, canConnectNow: peer.canConnect)
            })
            break
        }
    }
    
    fileprivate func disconnectSocket(socket: GCDAsyncSocket?, peer: BPPeer) {
        peer.state = .notConnected
        socket?.synchronouslySetDelegate(nil)
        socket?.disconnect()
        peer.socket = nil
    }
    
    public func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
        guard let peer = sock.peer else {
            dlog("WARNING, did not find peer in didReadData, doing nothing")
            return
        }
        self.scheduleNextKeepaliveTimer(peer)
        DispatchQueue.main.async {
            peer.lastDataRead = Date.init()
        }

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
            peer.connectCount += 1
            self.dispatch_on_delegate_queue({
                self.membershipRosterDelegate?.bluepeer?(self, peerDidConnect: peer.role, peer: peer)
            })
            dlog("\(peer.displayName).state=connected (auth OK), readHeaderTerminator1")
            sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
            
        } else if tag == DataTag.tag_HEADER.rawValue {
            // first, strip the trailing headerTerminator
            let range = 0..<data.count-self.headerTerminator.count
            let dataWithoutTerminator = data.subdata(in: range)
            if dataWithoutTerminator == self.keepAliveHeader {
                dlog("readKeepAlive from \(peer.displayName)")
                sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
            } else {
                // take the first 4 bytes and use them as UInt of length of data. read the next 4 bytes and discard for now, might use them for versioning/feature-supported in future, where clients are allowed to connect but have different feature abilities (as opposed to limiting what services you can see)
                var length: UInt = 0
                (dataWithoutTerminator as NSData).getBytes(&length, length: 4)
                // ignore bytes 4-8 for now
                dlog("got header, reading \(length) bytes from \(peer.displayName)...")
                peer.clientReceivedBytes = 0
                self.dispatch_on_delegate_queue({
                    self.dataDelegate?.bluepeer?(self, receivingData: 0, totalBytes: Int(length), peer: peer)
                })
                sock.readData(toLength: length, withTimeout: Timeouts.body.rawValue, tag: Int(length))
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
                let indexOfPeer = self.peers.firstIndex(of: existingPeer)!
                dlog("about to remove dupe peer \(existingPeer.displayName) from index \(indexOfPeer), had socket: \(existingPeer.socket != nil ? "ACTIVE" : "nil"). Peers(n=\(self.peers.count)) before removal")
                peer.connectAttemptFailCount += existingPeer.connectAttemptFailCount
                peer.connectAttemptFailAuthRejectCount += existingPeer.connectAttemptFailAuthRejectCount
                peer.connectCount += existingPeer.connectCount
                peer.disconnectCount += existingPeer.disconnectCount
                peer.dataRecvCount += existingPeer.dataRecvCount
                peer.dataSendCount += existingPeer.dataSendCount
//                existingPeer.destroyServices()
                if existingPeer.customData.count > 0 {
                    var newCustomData = peer.customData
                    if newCustomData.count > 0 {
                        newCustomData.merge(with: existingPeer.customData)
                    } else {
                        peer.customData = existingPeer.customData
                    }
                }
                peer.services.append(contentsOf: existingPeer.services)
                existingPeer.keepaliveTimer?.invalidate()
                existingPeer.keepaliveTimer = nil
                self.disconnectSocket(socket: existingPeer.socket, peer: existingPeer)
                self.peers.remove(at: indexOfPeer)
                dlog("... removed")
            }
            
            if let delegate = self.membershipAdminDelegate {
                self.dispatch_on_delegate_queue({
                    delegate.bluepeer?(self, peerConnectionRequest: peer, invitationHandler: { [weak self] (inviteAccepted) in
                        guard let self = self else { return }
                        if peer.state != .awaitingAuth || sock.isConnected != true {
                            self.dlog("inviteHandlerBlock: not connected/wrong state, so cannot accept!")
                            if (sock.isConnected) {
                                self.disconnectSocket(socket: sock, peer: peer)
                            }
                        } else if inviteAccepted {
                            peer.state = .authenticated // SERVER-local-peer becomes connected
                            peer.connectCount += 1
                            // CONVENTION: SERVER sends CLIENT a single 0 to show connection has been accepted, since it isn't possible to send a header for a payload of size zero except here.
                            sock.write(Data.init(count: 1), withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_WRITING.rawValue)
                            self.dlog("inviteHandlerBlock: accepted \(peer.displayName) (by my delegate), reading header...")
                            self.dispatch_on_delegate_queue({
                                self.membershipRosterDelegate?.bluepeer?(self, peerDidConnect: .client, peer: peer)
                            })
                            self.scheduleNextKeepaliveTimer(peer) // NEW in 1.1: if the two sides open up a connection but no one says anything, make sure it stays open
                            sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
                        } else {
                            self.dlog("inviteHandlerBlock: auth-rejected \(peer.displayName) (by my delegate)")
                            self.disconnectSocket(socket: sock, peer: peer)
                        }
                    })
                })
            }
            
        } else { // BODY/data case
            var data = data
            if let algorithm = self.compressionAlgorithm {
                guard let uncompressedData = data.decompress(withAlgorithm: algorithm) else {
                    assert(false, "Could not decompress data")
                    return
                }
                data = uncompressedData
            }
            peer.clientReceivedBytes = 0
            self.dispatch_on_delegate_queue({
                self.dataDelegate?.bluepeer?(self, receivingData: tag, totalBytes: tag, peer: peer)
                self.dataDelegate?.bluepeer(self, didReceiveData: data, peer: peer)
            })
            sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
        }
    }
    
    public func socket(_ sock: GCDAsyncSocket, didReadPartialDataOfLength partialLength: UInt, tag: Int) {
        guard let peer = sock.peer else { return }
        self.scheduleNextKeepaliveTimer(peer)
        DispatchQueue.main.async {
            peer.lastDataRead = Date.init()
        }
        guard partialLength > 0 else { return }
        peer.clientReceivedBytes += Int(partialLength)
        self.dispatch_on_delegate_queue({
            self.dataDelegate?.bluepeer?(self, receivingData: peer.clientReceivedBytes, totalBytes: tag, peer: peer)
        })
    }
    
    private func updateKeepAlivesOnSend(peer: BPPeer, tag: Int) {
        DispatchQueue.main.async {
            if tag == DataTag.tag_WRITINGKEEPALIVE.rawValue {
                peer.lastDataKeepAliveWritten = Date.init()
            } else {
                peer.lastDataNonKeepAliveWritten = Date.init()
            }
        }
    }
    
    // New in 1.4.0: avoid sending keepalives while sending data
    public func socket(_ sock: GCDAsyncSocket, didWritePartialDataOfLength partialLength: UInt, tag: Int) {
        guard let peer = sock.peer else { return }
        updateKeepAlivesOnSend(peer: peer, tag: tag)
    }
    
    // New in 1.4.0: avoid sending keepalives while sending data
    public func socket(_ sock: GCDAsyncSocket, didWriteDataWithTag tag: Int) {
        guard let peer = sock.peer else { return }
        updateKeepAlivesOnSend(peer: peer, tag: tag)
    }
    
    public func socket(_ sock: GCDAsyncSocket, shouldTimeoutReadWithTag tag: Int, elapsed: TimeInterval, bytesDone length: UInt) -> TimeInterval {
        return self.calcTimeExtension(sock, tag: tag)
    }
    public func socket(_ sock: GCDAsyncSocket, shouldTimeoutWriteWithTag tag: Int, elapsed: TimeInterval, bytesDone length: UInt) -> TimeInterval {
        return self.calcTimeExtension(sock, tag: tag)
    }
    
    public func calcTimeExtension(_ sock: GCDAsyncSocket, tag: Int) -> TimeInterval {
        guard let peer = sock.peer else {
            return 0
        }
        
        assert(!Thread.current.isMainThread)
        // it can happen that while sending lots of data, we don't receive keepalives that the other side is sending.
        // so if we are sending real data succesfully, don't time out
        var timeSinceLastDataRead: Double?
        var timeSinceLastDataWrittenWithoutKeepAlives: Double?
        DispatchQueue.main.sync {
            timeSinceLastDataRead = abs(peer.lastDataRead.timeIntervalSinceNow)
            timeSinceLastDataWrittenWithoutKeepAlives = abs(peer.lastDataNonKeepAliveWritten.timeIntervalSinceNow)
        }
        guard let timeSinceRead = timeSinceLastDataRead, let timeSinceWrite = timeSinceLastDataWrittenWithoutKeepAlives else {
            assert(false)
            return Timeouts.keepAlive.rawValue
        }
        let timeSince = min(timeSinceRead, timeSinceWrite)
        if timeSince > (2.0 * Timeouts.keepAlive.rawValue) {
            // timeout!
            dlog("keepalive: socket timed out waiting for read/write. timeSinceRead: \(timeSinceRead), timeSinceWrite: \(timeSinceWrite). Tag: \(tag). Disconnecting.")
            sock.disconnect()
            return 0
        }
        // extend
        dlog("keepalive: extending socket timeout by \(Timeouts.keepAlive.rawValue)s bc I saw data \(timeSince)s ago")
        return Timeouts.keepAlive.rawValue
    }
}

extension BluepeerObject: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard self.bluetoothPeripheralManager != nil else {
            dlog("!!!!!! BluepeerObject bluetooth state change with no bluetoothPeripheralManager !!!!!")
            return
        }
        dlog("Bluetooth status: ")
        switch (self.bluetoothPeripheralManager.state) {
        case .unknown:
            dlog("Unknown")
            self.bluetoothState = .unknown
        case .resetting:
            dlog("Resetting")
            self.bluetoothState = .other
        case .unsupported:
            dlog("Unsupported")
            self.bluetoothState = .other
        case .unauthorized:
            dlog("Unauthorized")
            self.bluetoothState = .other
        case .poweredOff:
            dlog("PoweredOff")
            self.bluetoothState = .poweredOff
        case .poweredOn:
            dlog("PoweredOn")
            self.bluetoothState = .poweredOn
        @unknown default:
            dlog("WARNING: unknown Bluetooth state")
            break
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

@available(iOS 13.0, *)
extension CBManagerAuthorization : CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .allowedAlways: return "allowedAlways"
        case .denied: return "DENIED"
        case .notDetermined: return "notDetermined"
        case .restricted: return "RESTRICTED"
        default: return "UNKNOWN!"
        }
    }
}
