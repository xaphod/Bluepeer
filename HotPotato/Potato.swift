//
//  Potato.swift
//  Created by Tim Carr on 2017-03-24.
//  Copyright © 2017 Tim Carr. All rights reserved.


import Foundation
import ObjectMapper

let MaxPotatoVisitLength = 10

public struct Potato {
    public var payload: Data? // Does NOT map
    public var visits: [PotatoVisit]?
}

extension Potato : Mappable {
    public init?(map: Map) {
        if map.JSON["visits"] == nil {
            assert(false, "ERROR")
            return nil
        }
    }
    
    mutating public func mapping(map: Map) {
        visits <- map["visits"]
    }
}
