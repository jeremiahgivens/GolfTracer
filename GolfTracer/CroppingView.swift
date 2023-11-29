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
    @State var value: ClosedRange<Float> = ClosedRange(uncheckedBounds: (0, 50))
    @State var bounds: ClosedRange<Int> = ClosedRange(uncheckedBounds: (0, 70))
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            VStack{
                if (url != nil){
                    VideoPlayer(player: AVPlayer(url: url!))
                        .frame(maxWidth: .infinity)
                }
                HStack{
                    Spacer()
                    Spacer()
                    Spacer()
                    Spacer()
                    RangedSliderView(viewModel: RangedSliderView.ViewModel(sliderPosition: value, sliderBounds: bounds), sliderPositionChanged: GetSliderRange)
                    Spacer()
                    Spacer()
                    Spacer()
                    Spacer()
                }
                Spacer()
                Spacer()
                Spacer()
                Spacer()
            }
        }
    }
    
    func GetSliderRange(range: ClosedRange<Float>){
        
    }
}

