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
    @State private var videoAnalysisState = LoadState.unknown
    @State private var newVideoURL: URL?
    
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
                                videoAnalysisState = .loading
                                Task{
                                    LoadVideoTrack(inputUrl: movie!.url)
                                }
                            }
                            case .failed:
                                Text("Import failed")
                        }
                        switch videoAnalysisState {
                        case .unknown:
                            EmptyView()
                        case .loading:
                            ProgressView()
                        case .loaded:
                            NavigationLink("View Analyzed Video") {
                                ZStack {
                                    Color.black
                                        .ignoresSafeArea()
                                    VideoPlayer(player: AVPlayer(url: newVideoURL!))
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        case .failed:
                            Text("Video analysis failed.")
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
        
        var newImage = image.transformed(by: scaleTransform)
        
        return newImage
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
        let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        let reader = try! AVAssetReader(asset: asset)
        asset.loadTracks(withMediaType: AVMediaType.video, completionHandler: {videoTrack, error in
            AnalyzeVideo(videoTrackOptional: videoTrack, error: error, reader: reader, asset: asset, timeRange: timeRange)
        })
    }
    
    func AnalyzeVideo(videoTrackOptional: [AVAssetTrack]?, error: Error?, reader: AVAssetReader, asset: AVAsset, timeRange: CMTimeRange){
        // read video frames as BGRA
        if let videoTrack = videoTrackOptional {
            let trackReaderOutput = AVAssetReaderTrackOutput(track: videoTrack[0], outputSettings:[String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: kCVPixelFormatType_32BGRA)])

            reader.add(trackReaderOutput)
            reader.startReading()
            
            var coordinates = [[[Float]]]()
            var confidences = [[[Float]]]()
            var timeStamps = [Double]()
            
            do {
                let model = try golfTracerModel()
                
                while let sampleBuffer = trackReaderOutput.copyNextSampleBuffer() {
                    print("sample at time \(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))")
                    if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        // process each CVPixelBufferRef here
                        guard let resized = resizePixelBuffer(imageBuffer) else { return }
                        let input = golfTracerModelInput(image: resized, iouThreshold: 0.45, confidenceThreshold: 0.25)
                        let preds = try model.prediction(input: input)
                        
                        if let b = try? UnsafeBufferPointer<Float>(preds.coordinates) {
                            let c = Array(b)
                            var output = [[Float]]()
                            for object in 0..<c.count/4{
                                var coord = [Float]()
                                for element in 0..<4{
                                    coord.append(c[object + element])
                                }
                                output.append(coord)
                            }
                            coordinates.append(output)
                        }
                        
                        if let b = try? UnsafeBufferPointer<Float>(preds.confidence) {
                            let c = Array(b)
                            var output = [[Float]]()
                            for object in 0..<c.count/2{
                                var conf = [Float]()
                                for element in 0..<2{
                                    conf.append(c[object + element])
                                }
                                output.append(conf)
                            }
                            confidences.append(output)
                        }
                        
                        
                        let presTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer);
                        let frameTime = CMTimeGetSeconds(presTime);
                        timeStamps.append(frameTime)
                    }
                }
                AnnotateVideo(assetTrack: videoTrack[0], asset: asset, coordinates: coordinates, confidences: confidences, timeStamps: timeStamps, timeRange: timeRange)
            } catch {
                print("There was an error trying to process your video.")
            }
        }
    }
    
    func AnnotateVideo(assetTrack: AVAssetTrack, asset: AVAsset, coordinates: [[[Float]]], confidences: [[[Float]]], timeStamps: [Double], timeRange: CMTimeRange) {
        print(coordinates)
        var composition = AVMutableComposition()
        guard
          let compositionTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
          else {
            print("Something is wrong with the asset.")
            return
        }
        
        do {
            try compositionTrack.insertTimeRange(timeRange, of: assetTrack, at: .zero)
            
            if let audioAssetTrack = asset.tracks(withMediaType: .audio).first,
              let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) {
              try compositionAudioTrack.insertTimeRange(
                timeRange,
                of: audioAssetTrack,
                at: .zero)
            }
        } catch {
            print("Something went wrong while creating new video.")
            print(error)
            videoAnalysisState = .failed
            return
        }
        
        compositionTrack.preferredTransform = assetTrack.preferredTransform
        let videoInfo = orientation(from: assetTrack.preferredTransform)
        
        let videoSize: CGSize
        if videoInfo.isPortrait {
          videoSize = CGSize(
            width: assetTrack.naturalSize.height,
            height: assetTrack.naturalSize.width)
        } else {
          videoSize = assetTrack.naturalSize
        }
        
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: videoSize)
        let overlayLayer = CALayer()
        overlayLayer.frame = CGRect(origin: .zero, size: videoSize)
        
        let outputLayer = CALayer()
        outputLayer.frame = CGRect(origin: .zero, size: videoSize)
        videoLayer.frame = CGRect(
          x: 20,
          y: 20,
          width: videoSize.width - 40,
          height: videoSize.height - 40)
        
        addBoundingBox(to: overlayLayer, videoSize: videoSize, coordinates: coordinates, confidences: confidences, timeStamps: timeStamps)
        outputLayer.addSublayer(videoLayer)
        outputLayer.addSublayer(overlayLayer)
        
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = videoSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
          postProcessingAsVideoLayer: videoLayer,
          in: outputLayer)
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
          start: .zero,
          duration: composition.duration)
        videoComposition.instructions = [instruction]
        let layerInstruction = compositionLayerInstruction(
          for: compositionTrack,
          assetTrack: assetTrack)
        instruction.layerInstructions = [layerInstruction]
        
        guard let export = AVAssetExportSession(
          asset: composition,
          presetName: AVAssetExportPresetHighestQuality)
          else {
            print("Cannot create export session.")
            return
        }
        
        let videoName = UUID().uuidString
        let exportURL = URL(fileURLWithPath: NSTemporaryDirectory())
          .appendingPathComponent(videoName)
          .appendingPathExtension("mov")

        export.videoComposition = videoComposition
        export.outputFileType = .mov
        export.outputURL = exportURL
        
        export.exportAsynchronously {
          DispatchQueue.main.async {
            switch export.status {
            case .completed:
                // Call your method to display the video
                newVideoURL = exportURL
                videoAnalysisState = .loaded
                break
            default:
              print("Something went wrong during export.")
              print(export.error ?? "unknown error")
              break
            }
          }
        }
    }
    
    private func compositionLayerInstruction(for track: AVCompositionTrack, assetTrack: AVAssetTrack) -> AVMutableVideoCompositionLayerInstruction {
      let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
      let transform = assetTrack.preferredTransform
      
      instruction.setTransform(transform, at: .zero)
      
      return instruction
    }
    
    private func addConfetti(to layer: CALayer) {
      let images: [UIImage] = (0...5).map { UIImage(named: "confetti\($0)")! }
      let colors: [UIColor] = [.systemGreen, .systemRed, .systemBlue, .systemPink, .systemOrange, .systemPurple, .systemYellow]
      let cells: [CAEmitterCell] = (0...16).map { _ in
        let cell = CAEmitterCell()
        cell.contents = images.randomElement()?.cgImage
        cell.birthRate = 3
        cell.lifetime = 12
        cell.lifetimeRange = 0
        cell.velocity = CGFloat.random(in: 100...200)
        cell.velocityRange = 0
        cell.emissionLongitude = 0
        cell.emissionRange = 0.8
        cell.spin = 4
        cell.color = colors.randomElement()?.cgColor
        cell.scale = CGFloat.random(in: 0.2...0.8)
        return cell
      }
      
      let emitter = CAEmitterLayer()
      emitter.emitterPosition = CGPoint(x: layer.frame.size.width / 2, y: layer.frame.size.height + 5)
      emitter.emitterShape = .line
      emitter.emitterSize = CGSize(width: layer.frame.size.width, height: 2)
      emitter.emitterCells = cells
      
      layer.addSublayer(emitter)
    }
    
    private func addImage(to layer: CALayer, videoSize: CGSize) {
      let image = UIImage(named: "overlay")!
      let imageLayer = CALayer()
        let aspect: CGFloat = image.size.width / image.size.height
        let width = videoSize.width
        let height = width / aspect
        imageLayer.frame = CGRect(
          x: 0,
          y: -height * 0.15,
          width: width,
          height: height)
        imageLayer.contents = image.cgImage
        layer.addSublayer(imageLayer)
    }

    
    private func orientation(from transform: CGAffineTransform) -> (orientation: UIImage.Orientation, isPortrait: Bool) {
      var assetOrientation = UIImage.Orientation.up
      var isPortrait = false
      if transform.a == 0 && transform.b == 1.0 && transform.c == -1.0 && transform.d == 0 {
        assetOrientation = .right
        isPortrait = true
      } else if transform.a == 0 && transform.b == -1.0 && transform.c == 1.0 && transform.d == 0 {
        assetOrientation = .left
        isPortrait = true
      } else if transform.a == 1.0 && transform.b == 0 && transform.c == 0 && transform.d == 1.0 {
        assetOrientation = .up
      } else if transform.a == -1.0 && transform.b == 0 && transform.c == 0 && transform.d == -1.0 {
        assetOrientation = .down
      }
      
      return (assetOrientation, isPortrait)
    }
    
    private func add(text: String, to layer: CALayer, videoSize: CGSize) {
      let attributedText = NSAttributedString(
        string: text,
        attributes: [
          .font: UIFont(name: "ArialRoundedMTBold", size: 60) as Any,
          .foregroundColor: UIColor(named: "rw-green")!,
          .strokeColor: UIColor.white,
          .strokeWidth: -3])
      
      let textLayer = CATextLayer()
      textLayer.string = attributedText
      textLayer.shouldRasterize = true
      textLayer.rasterizationScale = UIScreen.main.scale
      textLayer.backgroundColor = UIColor.clear.cgColor
      textLayer.alignmentMode = .center
      
      textLayer.frame = CGRect(
        x: 0,
        y: videoSize.height * 0.66,
        width: videoSize.width,
        height: 150)
      textLayer.displayIfNeeded()
      
      let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
      scaleAnimation.fromValue = 0.8
      scaleAnimation.toValue = 1.2
      scaleAnimation.duration = 0.5
      scaleAnimation.repeatCount = .greatestFiniteMagnitude
      scaleAnimation.autoreverses = true
      scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      
      scaleAnimation.beginTime = AVCoreAnimationBeginTimeAtZero
      scaleAnimation.isRemovedOnCompletion = false
      textLayer.add(scaleAnimation, forKey: "scale")
      
      layer.addSublayer(textLayer)
    }
    
    private func addBoundingBox(to layer: CALayer, videoSize: CGSize, coordinates: [[[Float]]], confidences: [[[Float]]], timeStamps: [Double]){
        let shapeLayer = CAShapeLayer()
        shapeLayer.frame = CGRect(origin: .zero, size: videoSize)
        var box = CGRect(x: Double(coordinates[0][0][0]), y: Double(coordinates[0][0][1]), width: Double(coordinates[0][0][2]), height: Double(coordinates[0][0][3]))
        
        let path = CGPath(rect: localToPixel(local: box, videoSize: videoSize), transform: nil)
        shapeLayer.path = path
        shapeLayer.strokeColor = UIColor.red.cgColor
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.lineWidth = 20;
        
        layer.addSublayer(shapeLayer)
    }
    
    private func localToPixel(local: CGRect, videoSize: CGSize) -> CGRect{
        var pixelRect = CGRect(x: local.midX*videoSize.width, y: local.midY*videoSize.height, width: local.width*videoSize.width, height: local.height*videoSize.height)
        
        return pixelRect
    }
}

#Preview {
    ContentView()
}
