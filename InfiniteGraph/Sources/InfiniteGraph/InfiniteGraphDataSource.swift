//
//  InfiniteGraphDataSource.swift
//  InfiniteGraph
//
//  Created by Boris Golovnev on 21/5/21.
//

import Foundation

public protocol InfiniteGraphDataSource : AnyObject {
    func getData(from:Int, to:Int) -> [Int32]
    var valuesPerPoint:CGFloat { get }
    var valueScale:CGFloat { get }
    var numValues:Int { get }
}
