//
//  Debug.swift
//  macSup2Srt
//
//  Created by Ethan Dye on 9/7/24.
//

public func debugPrint(_ object: Any...) {
    #if DEBUG
        for object in object {
            Swift.print(object)
        }
    #endif
}

public func debugPrint(_ object: Any) {
    #if DEBUG
        Swift.print(object)
    #endif
}
