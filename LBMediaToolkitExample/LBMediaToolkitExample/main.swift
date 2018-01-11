//
//  main.swift
//  LBMediaToolkitExample
//
//  Created by nevyn Bengtsson on 2018-01-11.
//  Copyright © 2018 nevyn Bengtsson. All rights reserved.
//

import Foundation
import CoreMedia

print("Hello, World!")


let asbd = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: 0, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: 0, mBitsPerChannel: 0, mReserved: 0)
let converter = LBAudioConverter(convertingTo: asbd)
