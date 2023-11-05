//
//  ContentView.swift
//  GolfTracer
//
//  Created by Jeremiah Givens on 11/1/23.
//

import SwiftUI
import AVKit
import AVFoundation
import PhotosUI
import CoreImage
import CoreGraphics
import Foundation
import CoreML

struct Movie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = URL.documentsDirectory.appending(path: "movie.mp4")

            if FileManager.default.fileExists(atPath: copy.path()) {
                try FileManager.default.removeItem(at: copy)
            }

            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self.init(url: copy)
        }
    }
}


struct ContentView: View {
    enum LoadState {
        case unknown, loading, loaded, failed
    }

    @State private var selectedItem: PhotosPickerItem?
    @State private var loadState = LoadState.unknown
    @State private var movie: Movie?
    
    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(colors: [.green, .black], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                Form {
                    Section {
                        PhotosPicker("Select Video", selection: $selectedItem, matching: .videos)
                        switch loadState {
                            case .unknown:
                                EmptyView()
                            case .loading:
                                ProgressView()
                            case .loaded:
                                NavigationLink("View Video") {
                                    ZStack {
                                        Color.black
                                            .ignoresSafeArea()
                                        VideoPlayer(player: AVPlayer(url: movie!.url))
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                            case .failed:
                                Text("Import failed")
                        }
                    }
                    
                    Section {
                        NavigationLink("Crop Video") {
                            Text("View coming soon")
                        }
                        NavigationLink("Trace Time Range") {
                            Text("View coming soon")
                        }
                    }
                    
                    Section {
                        switch loadState {
                            case .unknown:
                                EmptyView()
                            case .loading:
                                ProgressView()
                            case .loaded:
                            Button("Analyze Video"){
                                Task{
                                    LoadVideoTrack(inputUrl: movie!.url)
                                }
                            }
                            case .failed:
                                Text("Import failed")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Golf Tracer")
        }
        .onChange(of: selectedItem) {
            Task {
                do {
                    loadState = .loading

                    if let loadedMovie = try await selectedItem?.loadTransferable(type: Movie.self) {
                        do {
                            try AVAudioSession.sharedInstance().setCategory(.playback)
                        } catch(let error) {
                            print(error.localizedDescription)
                        }
                        loadState = .loaded
                        self.movie = loadedMovie
                    } else {
                        loadState = .failed
                    }
                } catch {
                    loadState = .failed
                }
            }
        }
    }
    
    func convertCIImageToCVPixelBuffer(_ image: CIImage) -> CVPixelBuffer? {
        let context = CIContext()

        let width = Int(image.extent.width)
        let height = Int(image.extent.height)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)

        if let pixelBuffer = pixelBuffer {
            context.render(image, to: pixelBuffer)
            return pixelBuffer
        }

        return nil
    }
    
    func resizeCIImage(_ image: CIImage) -> CIImage {
        let targetSize = CGSize(width: 1280, height: 1280)
        let scaleX = targetSize.width / image.extent.width
        let scaleY = targetSize.height / image.extent.height

        let scaleTransform = CGAffineTransform(scaleX: scaleX, y: scaleY)
        return image.transformed(by: scaleTransform)
    }
    
    func resizePixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        let resizedImage = resizeCIImage(ciImage)
        
        if let newPixelBuffer = convertCIImageToCVPixelBuffer(resizedImage){
            return newPixelBuffer
        } else {
            return nil
        }
    }
    
    func LoadVideoTrack(inputUrl: URL){
        let asset = AVAsset(url: inputUrl)
        let reader = try! AVAssetReader(asset: asset)
        asset.loadTracks(withMediaType: AVMediaType.video, completionHandler: {videoTrack, error in
            AnalyzeVideo(videoTrackOptional: videoTrack, error: error, reader: reader, asset: asset)
        })
    }
    
    func AnalyzeVideo(videoTrackOptional: [AVAssetTrack]?, error: Error?, reader: AVAssetReader, asset: AVAsset){
        // read video frames as BGRA
        if let videoTrack = videoTrackOptional {
            let trackReaderOutput = AVAssetReaderTrackOutput(track: videoTrack[0], outputSettings:[String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: kCVPixelFormatType_32BGRA)])

            reader.add(trackReaderOutput)
            reader.startReading()
            
            do {
                let model = try golfTracerModel()
                
                while let sampleBuffer = trackReaderOutput.copyNextSampleBuffer() {
                    print("sample at time \(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))")
                    if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        // process each CVPixelBufferRef here
                        guard let resized = resizePixelBuffer(imageBuffer) else { return }
                        let input = golfTracerModelInput(image: resized, iouThreshold: 0.45, confidenceThreshold: 0.25)
                        let predictions = try model.prediction(input: input)
                        print(predictions.coordinates)
                        print(predictions.confidence)
                    }
                }
            } catch {
                print("There was an error trying to process your video.")
            }
        }
    }
    
}

#Preview {
    ContentView()
}
