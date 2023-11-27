//
//  ContentView.swift
//  GolfTracer
//
//  Created by Jeremiah Givens on 11/1/23.
//

import SwiftUI
import AVKit
import PhotosUI


struct ContentView: View {
    
    @StateObject private var viewModel = ViewModel()
    
    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(colors: [.green, .black], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                Form {
                    Section {
                        PhotosPicker("Select Video", selection: $viewModel.selectedItem, matching: .videos)
                        switch viewModel.loadState {
                            case .unknown:
                                EmptyView()
                            case .loading:
                                ProgressView()
                            case .loaded:
                                NavigationLink("View Video") {
                                    ZStack {
                                        Color.black
                                            .ignoresSafeArea()
                                        VideoPlayer(player: AVPlayer(url: viewModel.originalMovie!.url))
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                            case .failed:
                                Text("Import failed")
                        }
                    }
                    
                    Section {
                        switch viewModel.loadState {
                            case .unknown:
                                EmptyView()
                            case .loading:
                                EmptyView()
                            case .loaded:
                                NavigationLink("Crop Video") {
                                    Text("View coming soon")
                                }
                                NavigationLink("Trace Time Range") {
                                    Text("View coming soon")
                                }
                            case .failed:
                                EmptyView()
                        }
                    }
                    
                    Section {
                        switch viewModel.loadState {
                            case .unknown:
                                EmptyView()
                            case .loading:
                                ProgressView()
                            case .loaded:
                            Button("Analyze Video"){
                                viewModel.videoAnalysisState = .loading
                                Task{
                                    viewModel.LoadVideoTrack(inputUrl: viewModel.originalMovie!.url)
                                }
                            }
                            case .failed:
                                Text("Import failed")
                        }
                        switch viewModel.videoAnalysisState {
                        case .unknown:
                            EmptyView()
                        case .loading:
                            ProgressView()
                        case .loaded:
                            NavigationLink("View Analyzed Video") {
                                ZStack {
                                    Color.black
                                        .ignoresSafeArea()
                                    VideoPlayer(player: AVPlayer(url: viewModel.annotatedVideoURL!))
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            Button("Save video to Photos"){
                                viewModel.ExportVideoToPhotosLibrary()
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
        .onChange(of: viewModel.selectedItem) {
            Task {
                do {
                    viewModel.loadState = .loading
                    viewModel.videoAnalysisState = .unknown

                    if let loadedMovie = try await viewModel.selectedItem?.loadTransferable(type: Movie.self) {
                        do {
                            try AVAudioSession.sharedInstance().setCategory(.playback)
                        } catch(let error) {
                            print(error.localizedDescription)
                        }
                        viewModel.loadState = .loaded
                        viewModel.originalMovie = loadedMovie
                    } else {
                        viewModel.loadState = .failed
                    }
                } catch {
                    viewModel.loadState = .failed
                }
            }
        }
    }
    
}

#Preview {
    ContentView()
}
