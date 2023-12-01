//
//  CroppingView.swift
//  GolfTracer
//
//  Created by Jeremiah Givens on 11/28/23.
//

import SwiftUI
import AVKit

struct CroppingView: View {
    var url: URL?
    let avPlayer: AVPlayer?
    var duration: CMTime?
    @State var value: ClosedRange<Float> = ClosedRange(uncheckedBounds: (0, 1))
    @State var bounds: ClosedRange<Float> = ClosedRange(uncheckedBounds: (0, 1))
    
    init(url: URL? = nil) {
        self.url = url
        if url != nil{
            var asset = AVAsset(url: url!)
            duration = asset.duration
            avPlayer = AVPlayer(url: url!)
        } else {
            avPlayer = nil
        }
    }
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            VStack{
                if (url != nil){
                    VideoPlayer(player: avPlayer)
                        .frame(maxWidth: .infinity)
                }
                HStack{
                    Spacer(minLength: 50)
                    RangedSliderView(viewModel: RangedSliderView.ViewModel(sliderPosition: value, sliderBounds: bounds), sliderPositionChanged: GetSliderRange)
                    Spacer(minLength: 50)
                }
                Spacer(minLength: 50)
            }
        }
    }
    
    func GetSliderRange(range: ClosedRange<Float>){
        print(range)
        if (duration != nil){
            avPlayer?.seek(to: CMTime(seconds: Double(range.lowerBound) * duration!.seconds, preferredTimescale: duration!.timescale))
        }
    }
}

#Preview {
    CroppingView(url: Bundle.main.url(forResource: "IMG_6877", withExtension: "MOV")!)
}

