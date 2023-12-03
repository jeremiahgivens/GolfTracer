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
                        .disabled(true)
                }
                HStack{
                    Spacer(minLength: 50)
                    Button {
                        if viewModel.isPlaying{
                            viewModel.PauseVideo()
                        } else {
                            viewModel.StartVideoFromCorrectSpot()
                        }
                    } label: {
                        if viewModel.isPlaying{
                            Image(systemName: "pause")
                                .frame(width: 40, height: 30)
                        } else {
                            Image(systemName: "play")
                                .frame(width: 40, height: 30)
                        }
                        
                    }
                        .buttonStyle(.borderedProminent)
                    Spacer(minLength: 20)
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
        @Published var videoRange: ClosedRange<Float> = ClosedRange(uncheckedBounds: (0, 1))
        @Published var isPlaying = false
        var timeBoundaryObserver: Any?

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
            videoRange = range
            if (duration != nil){
                let value = Double(isLeft ? range.lowerBound : range.upperBound)
                let time = CMTime(seconds: value * duration!.seconds, preferredTimescale: duration!.timescale)
                avPlayer?.seek(to: time, toleranceBefore: CMTime(value: 0, timescale: 1), toleranceAfter: CMTime(value: 0, timescale: 1))
            }
        }
        
        func PauseVideo(){
            self.avPlayer?.pause()
            self.isPlaying = false
        }
        
        func StartVideoFromCorrectSpot(){
            if duration != nil {
                let startTime = duration!.seconds * Double(videoRange.lowerBound);
                var stopTime = duration!.seconds * Double(videoRange.upperBound)
                
                if timeBoundaryObserver != nil {
                    avPlayer?.removeTimeObserver(timeBoundaryObserver!)
                }
                
                self.timeBoundaryObserver = self.avPlayer!.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: stopTime, preferredTimescale: duration!.timescale))], queue: DispatchQueue.main, using: { [unowned self] in
                    
                    Task{
                        await self.PauseVideo()
                    }
                    
                })
                
                if (avPlayer?.currentTime().seconds)! < startTime || (avPlayer?.currentTime().seconds)! >= stopTime{
                    let time = CMTime(seconds: startTime, preferredTimescale: duration!.timescale)
                    avPlayer?.seek(to: time, toleranceBefore: CMTime(value: 0, timescale: 1), toleranceAfter: CMTime(value: 0, timescale: 1))
                }
                avPlayer?.play()
                isPlaying = true
            }
        }
    }
}

#Preview {
    CroppingView(url: Bundle.main.url(forResource: "IMG_6877", withExtension: "MOV")!)
}

