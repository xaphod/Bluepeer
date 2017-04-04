//
//  HotPotatoMessages.swift
//
//  Created by Tim Carr on 2017-03-20.
//  Copyright © 2017 Tim Carr. All rights reserved.
//

import Foundation
import ObjectMapper

// Note: once something in the chain is StaticMappable, then all need to be StaticMappable

open class HotPotatoMessage : StaticMappable {
    static open let protocolVersion = 1
    var type: String? // sub-struct name ie. "Start"

    open class func objectForMapping(map: Map) -> BaseMappable? {
        guard let version: Int = map["version"].value(), version == HotPotatoMessage.protocolVersion, let type: String = map["type"].value() else {
            assert(false, "MALFORMED MESSAGE OR MISMATCHED VERSION")
            return nil
        }
        
        switch type {
        case "StartHotPotatoMessage":
            return StartHotPotatoMessage()
        case "PotatoHotPotatoMessage":
            return PotatoHotPotatoMessage()
        case "BuildGraphHotPotatoMessage":
            return BuildGraphHotPotatoMessage()
        case "RecoverHotPotatoMessage":
            return RecoverHotPotatoMessage()
        default:
            assert(false, "ERROR")
            return nil
        }
    }
    
    open func mapping(map: Map) {
        self.classNameAsString() >>> map["type"]
        HotPotatoMessage.protocolVersion >>> map["version"]
        type <- map["type"]
    }
    
    func classNameAsString() -> String {
        let parts = String(describing: self).components(separatedBy: ".")
        if parts.count == 0 {
            return parts[0]
        } else {
            return parts[1]
        }
    }
    
    init() {
    }
}

// means I want to start, I see N devices other than me, version of the data I have is FOO
open class StartHotPotatoMessage : HotPotatoMessage {
    var remoteDevices: Int?
    var dataVersion: String? // ISO 8601 date format
    var ID: Int? // to map answers to requests
    var livePeerNames: [String:Int64]?
    
    override init() {
        super.init()
    }
    
    convenience init(remoteDevices: Int, dataVersion: String, ID: Int, livePeerNames: [String:Int64]?) {
        self.init()
        self.remoteDevices = remoteDevices
        self.dataVersion = dataVersion
        self.ID = ID
        self.livePeerNames = livePeerNames
    }
    
    override open func mapping(map: Map) {
        super.mapping(map: map)
        remoteDevices <- map["remoteDevices"]
        dataVersion <- map["dataVersion"]
        ID <- map["ID"]
        livePeerNames <- map["livePeerNames"]
    }
}

open class PotatoHotPotatoMessage : HotPotatoMessage {
    var potato: Potato?
    override init() {
        super.init()
    }
    convenience init(potato: Potato) {
        self.init()
        self.potato = potato
    }
    override open func mapping(map: Map) {
        super.mapping(map: map)
        potato <- map["potato"]
    }
}

open class BuildGraphHotPotatoMessage : HotPotatoMessage {
    var myConnectedPeers: [String]?
    var myState: HotPotatoNetwork.State?
    var livePeerNames: [String:Int64]?
    var ID: Int? // to map answers to requests
    override init() {
        super.init()
    }
    convenience init(myConnectedPeers: [String], myState: HotPotatoNetwork.State, livePeerNames: [String:Int64], ID: Int) {
        self.init()
        self.myConnectedPeers = myConnectedPeers
        self.myState = myState
        self.livePeerNames = livePeerNames
        self.ID = ID
    }
    override open func mapping(map: Map) {
        super.mapping(map: map)
        myConnectedPeers <- map["myConnectedPeers"]
        myState <- map["myState"]
        livePeerNames <- map["livePeerNames"]
        ID <- map["ID"]
    }
}

open class RecoverHotPotatoMessage : HotPotatoMessage {
    var ID: Int? // to map answers to requests
    var livePeerNames: [String:Int64]?
    override init() {
        super.init()
    }
    convenience init(ID: Int, livePeerNames: [String:Int64]?) {
        self.init()
        self.ID = ID
        self.livePeerNames = livePeerNames
    }
    
    override open func mapping(map: Map) {
        super.mapping(map: map)
        ID <- map["ID"]
        livePeerNames <- map["livePeerNames"]
    }
}

