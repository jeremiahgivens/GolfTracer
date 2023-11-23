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
import VectorMath

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
    
    func resizePixelBuffer(_ pixelBuffer: CVPixelBuffer, imageOrientation: UIImage.Orientation) -> CVPixelBuffer? {

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        var resizedImage = resizeCIImage(ciImage)
        
        if (imageOrientation == UIImage.Orientation.right){
            resizedImage = resizedImage.oriented(.right)
        }
        
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
            
            var coordinates = [[[Float]]]()
            var confidences = [[[Float]]]()
            var timeStamps = [Double]()
            
            let videoInfo = orientation(from: videoTrack[0].preferredTransform)
            
            do {
                let model = try GolfTracerModel2()
                
                while let sampleBuffer = trackReaderOutput.copyNextSampleBuffer() {
                    print("sample at time \(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))")
                    if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        // process each CVPixelBufferRef here
                        try autoreleasepool {
                            guard let resized = resizePixelBuffer(imageBuffer, imageOrientation: videoInfo.orientation) else { return }
                            
                            let input = GolfTracerModel2Input(image: resized, iouThreshold: 0.45, confidenceThreshold: 0.25)
                            let preds = try model.prediction(input: input)

                            if let b = try? UnsafeBufferPointer<Float>(preds.coordinates) {
                                let c = Array(b)
                                var output = [[Float]]()
                                for object in 0..<c.count/4{
                                    var coord = [Float]()
                                    for element in 0..<4{
                                        coord.append(c[object*4 + element])
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
                                        conf.append(c[object*2 + element])
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
                }
            } catch {
                print("There was an error trying to process your video.")
                return
            }
            AnnotateVideo(assetTrack: videoTrack[0], asset: asset, coordinates: coordinates, confidences: confidences, timeStamps: timeStamps)
        }
    }
    
    func AnnotateVideo(assetTrack: AVAssetTrack, asset: AVAsset, coordinates: [[[Float]]], confidences: [[[Float]]], timeStamps: [Double]) {
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
            let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
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
        //addDetectionDots(to: overlayLayer, videoSize: videoSize, coordinates: coordinates, confidences: confidences, timeStamps: timeStamps)
        addTrace(to: overlayLayer, videoSize: videoSize, coordinates: coordinates, confidences: confidences, timeStamps: timeStamps)
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
    
    private func addTrace(to layer: CALayer, videoSize: CGSize, coordinates: [[[Float]]], confidences: [[[Float]]], timeStamps: [Double]){
        let shapeLayer = CAShapeLayer()
        shapeLayer.frame = CGRect(origin: .zero, size: videoSize)
        
        let pathAnimation = CAKeyframeAnimation(keyPath: "path")
        var paths = [CGPath]()
        var keyTimes = [Double]()
        
        var trace = [CGPoint]()
        var traceHeads = [[Float]]()
        var traceTimeStamps = [Double]()
        var lastClub = [Float]()

        for frame in 0..<coordinates.count{
            var clubs = [[Float]]()
            var heads = [[Float]]()
            
            // Find all of the club heads in this frame
            for i in 0..<coordinates[frame].count {
                if (confidences[frame][i][1] > confidences[frame][i][0]){
                    heads.append(coordinates[frame][i])
                } else {
                    clubs.append(coordinates[frame][i])
                }
            }
            
            if (frame == 0){
                var minDist : Float = 10
                var index : Int = -1
                // Find the club that is closest to the center (we will assume that the club is detected in the first frame)
                for i in 0..<clubs.count{
                    var v = Vector2(clubs[i][0] - 0.5, clubs[i][1] - 0.5)
                    var distFromCenter = v.length
                    if (i == 0 || distFromCenter < minDist){
                        minDist = distFromCenter
                        index = i
                    }
                }
                
                if (index != -1){
                    lastClub = clubs[index]
                }
            } else {
                // Find the club that has the biggest IOU with lastClub, and assign this to last club.
                var tempBox = [Float]()
                var maxIOU : Float = 0
                for i in 0..<clubs.count{
                    var IOU = IntersectionOverUnion(A: lastClub, B: clubs[i])
                    if IOU > maxIOU {
                        maxIOU = IOU
                        tempBox = clubs[i]
                    }
                }
                
                if !tempBox.isEmpty{
                    lastClub = tempBox
                }
            }
            
            let path = CGMutablePath()
            
            // now, find the club head that falls within the bounding box of lastClub.
            var canidateHeads = [[Float]]()
            for i in 0..<heads.count{
                var head = heads[i]
                let area = AreaOfIntersection(A: head, B: lastClub)
                if (area > 0){
                    canidateHeads.append(head)
                }
            }
            
            if (!canidateHeads.isEmpty){
                var head = [Float]()
                
                // If this is the the first detection, we will grab the point that is farthest from the center of the clubs bounding box
                if traceHeads.isEmpty {
                    var maxDistFromCenter : Float = 0
                    for i in 0..<canidateHeads.count{
                        var v = Vector2(canidateHeads[i][0] - lastClub[0], canidateHeads[i][1] - lastClub[1])
                        var distFromCenter = v.length
                        if (i == 0 || distFromCenter > maxDistFromCenter){
                            maxDistFromCenter = distFromCenter
                            head = canidateHeads[i]
                        }
                    }
                } else if traceHeads.count == 1 {
                    // Choose head that is closest to previously detected head.
                    var minDistFromLast : Float = 0
                    for i in 0..<canidateHeads.count{
                        var v = Vector2(canidateHeads[i][0] - traceHeads.last![0], canidateHeads[i][1] - traceHeads.last![1])
                        var dist = v.length
                        if (i == 0 || dist < minDistFromLast){
                            minDistFromLast = dist
                            head = canidateHeads[i]
                        }
                    }
                } else {
                    // Perform extrapolation and choose the point closest to our predicted point. We will use the last two detections and lagrange polynomials to predict the next point
                    var steps = 2
                    if traceHeads.count > 2 {
                        steps = 3
                    }
                    var points = Array(traceHeads[traceHeads.count - steps ... traceHeads.count - 1])
                    var times = Array(traceTimeStamps[traceTimeStamps.count - steps ... traceTimeStamps.count - 1])
                    var prediction = ExtrapolatedBox(points: points, times: times, predictionTime: timeStamps[frame])
                    
                    var minDistFromPrediction : Float = 0
                    for i in 0..<canidateHeads.count{
                        var v = Vector2(canidateHeads[i][0] - prediction[0], canidateHeads[i][1] - prediction[1])
                        var dist = v.length
                        if (i == 0 || dist < minDistFromPrediction){
                            minDistFromPrediction = dist
                            head = canidateHeads[i]
                        }
                    }
                }
                
                traceTimeStamps.append(timeStamps[frame])
                traceHeads.append(head)
                trace.append(LocalToPixel(local: CGPoint(x: Double(head[0]), y: 1 - Double(head[1])), videoSize: videoSize))
            }
            
            if !trace.isEmpty {
                path.move(to: trace[0])
            }
            
            for i in 0..<trace.count {
                // We will use the methods described here:
                // https://math.stackexchange.com/questions/1075521/find-cubic-bézier-control-points-given-four-points
                
                // first we convert our points to vectors:
                var p0 : Vector2
                var p1 : Vector2
                var p2 : Vector2
                var p3 : Vector3
                
                if i == 0 {
                    
                }
            }
            
            paths.append(path)
            keyTimes.append(timeStamps[frame]/timeStamps.last!)
        }
        
        pathAnimation.values = paths
        pathAnimation.keyTimes = keyTimes as [NSNumber]
        pathAnimation.beginTime = AVCoreAnimationBeginTimeAtZero
        pathAnimation.duration = timeStamps.last!
        pathAnimation.calculationMode = .discrete
        
        shapeLayer.add(pathAnimation, forKey: "path")
        
        //shapeLayer.path = paths[0]
        shapeLayer.strokeColor = UIColor.red.cgColor
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.lineWidth = 3;
        
        layer.addSublayer(shapeLayer)
    }
    
    private func ExtrapolatedBox(points: [[Float]], times: [Double], predictionTime: Double) -> [Float] {
        // https://en.wikipedia.org/wiki/Lagrange_polynomial
        // Points is expected to have two or three elements
        var prediction = [Float]()
        var basis = [Double]()
        
        // Construct the basis
        for i in 0..<points.count {
            basis.append(1)
            for j in 0..<points.count{
                if (j != i){
                    basis[i] *= (predictionTime - times[j])/(times[i] - times[j])
                }
            }
        }
        
        // Now we compute our predicted point
        for i in 0...1{
            prediction.append(0)
            for j in 0..<points.count {
                prediction[i] += points[j][i]*Float(basis[j])
            }
        }
        
        // And we will assume (for now) that the box dimensions stays the same
        for i in 2...3 {
            prediction.append(points.last![i])
        }
        
        return prediction
    }
    
    private func addBoundingBox(to layer: CALayer, videoSize: CGSize, coordinates: [[[Float]]], confidences: [[[Float]]], timeStamps: [Double]){
        let shapeLayer = CAShapeLayer()
        shapeLayer.frame = CGRect(origin: .zero, size: videoSize)
        
        let pathAnimation = CAKeyframeAnimation(keyPath: "path")
        var paths = [CGPath]()
        var keyTimes = [Double]()
        
        for frame in 0..<coordinates.count{
            var path = CGMutablePath()
            for i in 0..<coordinates[frame].count {
                if (confidences[frame][i][1] > confidences[frame][i][0] || true){
                    var cord = coordinates[frame][i]
                    var box = CGRect(x: Double(cord[0]), y: 1 - Double(cord[1]), width: Double(cord[2]), height: Double(cord[3]))
                    
                    let rectPath = CGPath(rect: LocalToShiftedPixelRect(local: box, videoSize: videoSize), transform: nil)
                    path.addPath(rectPath)
                }
            }
            
            paths.append(path)
            keyTimes.append(timeStamps[frame]/timeStamps.last!)
        }
        
        pathAnimation.values = paths
        pathAnimation.keyTimes = keyTimes as [NSNumber]
        pathAnimation.beginTime = AVCoreAnimationBeginTimeAtZero
        pathAnimation.duration = timeStamps.last!
        pathAnimation.calculationMode = .discrete
        
        shapeLayer.add(pathAnimation, forKey: "path")
        
        //shapeLayer.path = paths[0]
        shapeLayer.strokeColor = UIColor.red.cgColor
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.lineWidth = 3;
        
        layer.addSublayer(shapeLayer)
    }
    
    private func addDetectionDots(to layer: CALayer, videoSize: CGSize, coordinates: [[[Float]]], confidences: [[[Float]]], timeStamps: [Double]){
        let shapeLayer = CAShapeLayer()
        shapeLayer.frame = CGRect(origin: .zero, size: videoSize)
        
        let pathAnimation = CAKeyframeAnimation(keyPath: "path")
        var paths = [CGPath]()
        var keyTimes = [Double]()
        var pixelPoints = [CGPoint]()
        
        for frame in 0..<coordinates.count{
            var path = CGMutablePath()
            for i in 0..<coordinates[frame].count {
                if (confidences[frame][i][1] > confidences[frame][i][0]){
                    var cord = coordinates[frame][i]
                    /*
                    var box = CGRect(x: Double(cord[0]), y: 1 - Double(cord[1]), width: Double(cord[2]), height: Double(cord[3]))
                    
                    let rectPath = CGPath(rect: LocalToShiftedPixelRect(local: box, videoSize: videoSize), transform: nil)
                    path.addPath(rectPath)
                     */
                    var point = CGPoint(x: Double(cord[0]), y: 1 - Double(cord[1]))
                    var pixelPoint = LocalToPixel(local: point, videoSize: videoSize)
                    pixelPoints.append(pixelPoint)
                }
            }
            
            for j in 0..<pixelPoints.count{
                path.addRect(CGRect(x: pixelPoints[j].x - 2, y: pixelPoints[j].y - 2, width: 4, height: 4))
            }
            
            paths.append(path)
            keyTimes.append(timeStamps[frame]/timeStamps.last!)
        }
        
        pathAnimation.values = paths
        pathAnimation.keyTimes = keyTimes as [NSNumber]
        pathAnimation.beginTime = AVCoreAnimationBeginTimeAtZero
        pathAnimation.duration = timeStamps.last!
        pathAnimation.calculationMode = .discrete
        
        shapeLayer.add(pathAnimation, forKey: "path")
        
        //shapeLayer.path = paths[0]
        shapeLayer.strokeColor = UIColor.red.cgColor
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.lineWidth = 3;
        
        layer.addSublayer(shapeLayer)
    }
    
    private func LocalToPixel(local: CGPoint, videoSize: CGSize) -> CGPoint{
        var pixel = CGPoint(x: local.x*videoSize.width, y: local.y*videoSize.height)
        
        return pixel
    }
    
    private func LocalRectToPixelRect(local: CGRect, videoSize: CGSize) -> CGRect{
        var pixelRect = CGRect(x: local.minX*videoSize.width, y: local.minY*videoSize.height, width: local.width*videoSize.width, height: local.height*videoSize.height)
        
        return pixelRect
    }
    
    private func ShiftForRectangleCenter(local: CGRect) -> CGRect{
        var shiftedRect = CGRect(x: local.minX - local.width/2, y: local.minY - local.height/2, width: local.width, height: local.height)
        
        return shiftedRect
    }
    
    private func LocalToShiftedPixelRect(local: CGRect, videoSize: CGSize) -> CGRect{
        return LocalRectToPixelRect(local: ShiftForRectangleCenter(local: local), videoSize: videoSize)
    }
    
    private func AreaOfIntersection (A: [Float], B: [Float]) -> Float{
        let XA1 = A[0] - A[2]/2
        let XA2 = A[0] + A[2]/2
        let YA1 = A[1] - A[3]/2
        let YA2 = A[1] + A[3]/2
        
        let XB1 = B[0] - B[2]/2
        let XB2 = B[0] + B[2]/2
        let YB1 = B[1] - B[3]/2
        let YB2 = B[1] + B[3]/2
        
        var w : Float = max(0, min(XA2, XB2) - max(XA1, XB1))
        var h : Float = max(0, min(YA2, YB2) - max(YA1, YB1))
        
        var area : Float = w * h
        
        return area
    }
    
    private func Area(_ A: [Float]) -> Float{
        return A[2]*A[3]
    }
    
    private func AreaOfUnion (A: [Float], B: [Float]) -> Float{
        return Area(A) + Area(B) - AreaOfIntersection(A: A, B: B)
    }
    
    private func IntersectionOverUnion (A: [Float], B: [Float]) -> Float{
        return AreaOfIntersection(A: A, B: B)/AreaOfUnion(A: A, B: B)
    }
}

#Preview {
    ContentView()
}
