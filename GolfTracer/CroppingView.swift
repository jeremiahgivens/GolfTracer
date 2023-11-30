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
    @State var value: ClosedRange<Float> = ClosedRange(uncheckedBounds: (0, 1))
    @State var bounds: ClosedRange<Float> = ClosedRange(uncheckedBounds: (0, 1))
    
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
    }
}

#Preview {
    CroppingView(url: Bundle.main.url(forResource: "IMG_6877", withExtension: "MOV")!)
}

