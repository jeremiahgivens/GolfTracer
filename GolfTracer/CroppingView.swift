//
//  CroppingView.swift
//  GolfTracer
//
//  Created by Jeremiah Givens on 11/28/23.
//

import SwiftUI
import AVKit

struct CroppingView: View {
    @ObservedObject private var viewModel: ViewModel = ViewModel()
    
    init(url: URL? = nil) {
        viewModel.SetURL(url: url)
    }
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            VStack{
                if (viewModel.url != nil){
                    VideoPlayer(player: viewModel.avPlayer)
                        .frame(maxWidth: .infinity)
                }
                HStack{
                    Spacer(minLength: 50)
                    RangedSliderView(sliderPositionChanged: viewModel.GetSliderRange)
                    Spacer(minLength: 50)
                }
                Spacer(minLength: 50)
            }
        }
    }
}

extension CroppingView {
    @MainActor class ViewModel: ObservableObject {
        @Published var url: URL?
        @Published var avPlayer: AVPlayer?
        @Published var duration: CMTime?
        
        func SetURL(url: URL?){
            self.url = url
            if url != nil{
                let asset = AVAsset(url: url!)
                duration = asset.duration
                avPlayer = AVPlayer(url: url!)
            } else {
                avPlayer = nil
            }
        }
        
        func GetSliderRange(range: ClosedRange<Float>, isLeft: Bool){
            if (duration != nil){
                var value = Double(isLeft ? range.lowerBound : range.upperBound)
                let time = CMTime(seconds: value * duration!.seconds, preferredTimescale: duration!.timescale)
                avPlayer?.seek(to: time, toleranceBefore: CMTime(value: 0, timescale: 1), toleranceAfter: CMTime(value: 0, timescale: 1))
            }
        }
    }
}

#Preview {
    CroppingView(url: Bundle.main.url(forResource: "IMG_6877", withExtension: "MOV")!)
}

