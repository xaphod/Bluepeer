//
//  PotatoVisit.swift
//  Created by Tim Carr on 2017-03-24.
//  Copyright © 2017 Tim Carr. All rights reserved.


import Foundation
import ObjectMapper

public struct PotatoVisit {
    var peerName: String?
    var visitNum: Int?
    var connectedPeers: [String]?
}

extension PotatoVisit : Mappable {
    public init?(map: Map) {
        if map.JSON["peerName"] == nil || map.JSON["visitNum"] == nil || map.JSON["connectedPeers"] == nil {
            assert(false, "ERROR")
            return nil
        }
    }
    
    mutating public func mapping(map: Map) {
        peerName <- map["peerName"]
        visitNum <- map["visitNum"]
        connectedPeers <- map["connectedPeers"]
    }
}
