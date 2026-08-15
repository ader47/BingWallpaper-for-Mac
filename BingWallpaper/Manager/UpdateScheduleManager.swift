//
//  UpdateScheduleManager.swift
//  BingWallpaper
//
//  Created by Laurenz Lazarus on 06.11.22.
//

import Foundation

public class UpdateScheduleManager {
    
    private static let FETCH_INTERVAL: Double = 3600 * 3
    
    private init() { }
    
    public static func isUpdateNecessary() -> Bool {
        return isUpdateNecessary(lastUpdate: Settings().lastUpdate)
    }
    
    public static func nextFetchTimeInterval() -> TimeInterval {
        return nextFetchTimeInterval(lastUpdate: Settings().lastUpdate)
    }

    static func isUpdateNecessary(lastUpdate: Date, now: Date = Date()) -> Bool {
        return nextFetchTimeInterval(lastUpdate: lastUpdate, now: now) == 0
    }

    static func nextFetchTimeInterval(lastUpdate: Date, now: Date = Date()) -> TimeInterval {
        return max(0, FETCH_INTERVAL - abs(lastUpdate.timeIntervalSince(now)))
    }
        
}
