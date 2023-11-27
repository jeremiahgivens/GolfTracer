//
//  ContentView-ViewModel.swift
//  GolfTracer
//
//  Created by Jeremiah Givens on 11/25/23.
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

extension ContentView {
    @MainActor class ViewModel: ObservableObject {
        @Published var selectedItem: PhotosPickerItem?
        @Published var loadState = LoadState.unknown
        @Published var originalMovie: Movie?
        @Published var videoAnalysisState = LoadState.unknown
        @Published var annotatedVideoURL: URL?
        
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
            
            let newImage = image.transformed(by: scaleTransform)
            
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
                self.AnalyzeVideo(videoTrackOptional: videoTrack, error: error, reader: reader, asset: asset)
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
                    let model = try GolfTracerClubDetectionModel()
                    
                    while let sampleBuffer = trackReaderOutput.copyNextSampleBuffer() {
                        print("sample at time \(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))")
                        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                            // process each CVPixelBufferRef here
                            try autoreleasepool {
                                guard let resized = resizePixelBuffer(imageBuffer, imageOrientation: videoInfo.orientation) else { return }
                                
                                let input = GolfTracerClubDetectionModelInput(image: resized, iouThreshold: 0.45, confidenceThreshold: 0.05)
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
                    self.annotatedVideoURL = exportURL
                    self.videoAnalysisState = .loaded
                    break
                default:
                  print("Something went wrong during export.")
                  print(export.error ?? "unknown error")
                  break
                }
              }
            }
        }
        
        public func ExportVideoToPhotosLibrary(){
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: self.annotatedVideoURL!)
                    }) { saved, error in
                        if saved {
                            print("Saved")
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
            
            var clubDetected = false
            var lastQuadrant = 2

            for frame in 0..<coordinates.count{
                clubDetected = false
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
                        let v = Vector2(clubs[i][0] - 0.5, clubs[i][1] - 0.5)
                        let distFromCenter = v.length
                        if (i == 0 || distFromCenter < minDist){
                            minDist = distFromCenter
                            index = i
                        }
                    }
                    
                    if (index != -1){
                        lastClub = clubs[index]
                        clubDetected = true
                    }
                } else {
                    // Find the club that has the biggest IOU with lastClub, and assign this to last club.
                    var tempBox = [Float]()
                    var maxIOU : Float = 0
                    for i in 0..<clubs.count{
                        let IOU = IntersectionOverUnion(A: lastClub, B: clubs[i])
                        if IOU > maxIOU {
                            maxIOU = IOU
                            tempBox = clubs[i]
                        }
                    }
                    
                    if !tempBox.isEmpty{
                        lastClub = tempBox
                        clubDetected = true
                    }
                }
                
                let path = CGMutablePath()
                
                // now, find the club head that falls within the bounding box of lastClub.
                var canidateHeads = [[Float]]()
                for i in 0..<heads.count{
                    let head = heads[i]
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
                            let v = Vector2(canidateHeads[i][0] - lastClub[0], canidateHeads[i][1] - lastClub[1])
                            let distFromCenter = v.length
                            if (i == 0 || distFromCenter > maxDistFromCenter){
                                maxDistFromCenter = distFromCenter
                                head = canidateHeads[i]
                            }
                        }
                    } else if traceHeads.count == 1 {
                        // Choose head that is closest to previously detected head.
                        var minDistFromLast : Float = 0
                        for i in 0..<canidateHeads.count{
                            let v = Vector2(canidateHeads[i][0] - traceHeads.last![0], canidateHeads[i][1] - traceHeads.last![1])
                            let dist = v.length
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
                        let points = Array(traceHeads[traceHeads.count - steps ... traceHeads.count - 1])
                        let times = Array(traceTimeStamps[traceTimeStamps.count - steps ... traceTimeStamps.count - 1])
                        let prediction = ExtrapolatedBox(points: points, times: times, predictionTime: timeStamps[frame])
                        
                        var minDistFromPrediction : Float = 0
                        for i in 0..<canidateHeads.count{
                            let v = Vector2(canidateHeads[i][0] - prediction[0], canidateHeads[i][1] - prediction[1])
                            let dist = v.length
                            if (i == 0 || dist < minDistFromPrediction){
                                minDistFromPrediction = dist
                                head = canidateHeads[i]
                            }
                        }
                    }
                    
                    if (head[0] > lastClub[0] && head[1] > lastClub[1]){
                        lastQuadrant = 0
                    } else if (head[0] < lastClub[0] && head[1] > lastClub[1]){
                        lastQuadrant = 1
                    } else if (head[0] < lastClub[0] && head[1] < lastClub[1]){
                        lastQuadrant = 2
                    } else if (head[0] > lastClub[0] && head[1] < lastClub[1]){
                        lastQuadrant = 3
                    }
                    
                    traceTimeStamps.append(timeStamps[frame])
                    traceHeads.append(head)
                    trace.append(LocalToPixel(local: CGPoint(x: Double(head[0]), y: 1 - Double(head[1])), videoSize: videoSize))
                } else if (trace.count > 0 && clubDetected) {
                    // We will place a box the same size as the previous one in the same quadrant of the club box
                    let oldBox = traceHeads.last!
                    var newBox = [Float]()
                    
                    switch lastQuadrant {
                    case 0: do {
                        newBox.append(lastClub[0] + 0.5*(lastClub[2] - oldBox[2]))
                        newBox.append(lastClub[1] + 0.5*(lastClub[3] - oldBox[3]))
                        newBox.append(oldBox[2])
                        newBox.append(oldBox[3])
                    } case 1: do {
                        newBox.append(lastClub[0] - 0.5*(lastClub[2] - oldBox[2]))
                        newBox.append(lastClub[1] + 0.5*(lastClub[3] - oldBox[3]))
                        newBox.append(oldBox[2])
                        newBox.append(oldBox[3])
                    } case 2: do {
                        newBox.append(lastClub[0] - 0.5*(lastClub[2] - oldBox[2]))
                        newBox.append(lastClub[1] - 0.5*(lastClub[3] - oldBox[3]))
                        newBox.append(oldBox[2])
                        newBox.append(oldBox[3])
                    } case 3: do {
                        newBox.append(lastClub[0] + 0.5*(lastClub[2] - oldBox[2]))
                        newBox.append(lastClub[1] - 0.5*(lastClub[3] - oldBox[3]))
                        newBox.append(oldBox[2])
                        newBox.append(oldBox[3])
                    }
                    default:
                        print("Incorrect quadrant number")
                    }
                    
                    if !newBox.isEmpty {
                        let head = newBox
                        traceTimeStamps.append(timeStamps[frame])
                        traceHeads.append(head)
                        trace.append(LocalToPixel(local: CGPoint(x: Double(head[0]), y: 1 - Double(head[1])), videoSize: videoSize))
                    }
                }
                
                if !trace.isEmpty {
                    path.move(to: trace[0])
                }
                
                for i in 0..<trace.count - 1 {
                    path.addLine(to: trace[i + 1])
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
        
        private func ScalarMultiply(scalar: Float, vector: Vector2) -> Vector2{
            let scaledVector = Vector2(scalar*vector.x, scalar*vector.y)
            
            return scaledVector
        }
        
        private func Vector2ToCGPoint(v: Vector2) -> CGPoint {
            return CGPoint(x: Int(v.x), y: Int(v.y))
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
                let path = CGMutablePath()
                for i in 0..<coordinates[frame].count {
                    if (confidences[frame][i][1] > confidences[frame][i][0] || true){
                        let cord = coordinates[frame][i]
                        let box = CGRect(x: Double(cord[0]), y: 1 - Double(cord[1]), width: Double(cord[2]), height: Double(cord[3]))
                        
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
                let path = CGMutablePath()
                for i in 0..<coordinates[frame].count {
                    if (confidences[frame][i][1] > confidences[frame][i][0]){
                        let cord = coordinates[frame][i]
                        let point = CGPoint(x: Double(cord[0]), y: 1 - Double(cord[1]))
                        let pixelPoint = LocalToPixel(local: point, videoSize: videoSize)
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
            let pixel = CGPoint(x: local.x*videoSize.width, y: local.y*videoSize.height)
            
            return pixel
        }
        
        private func LocalRectToPixelRect(local: CGRect, videoSize: CGSize) -> CGRect{
            let pixelRect = CGRect(x: local.minX*videoSize.width, y: local.minY*videoSize.height, width: local.width*videoSize.width, height: local.height*videoSize.height)
            
            return pixelRect
        }
        
        private func ShiftForRectangleCenter(local: CGRect) -> CGRect{
            let shiftedRect = CGRect(x: local.minX - local.width/2, y: local.minY - local.height/2, width: local.width, height: local.height)
            
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
            
            let w : Float = max(0, min(XA2, XB2) - max(XA1, XB1))
            let h : Float = max(0, min(YA2, YB2) - max(YA1, YB1))
            
            let area : Float = w * h
            
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
    
    enum LoadState {
        case unknown, loading, loaded, failed
    }
    
    enum Quadrant {
        case quadrant0, quadrant1, quadrant2, quadrant3
    }
}
