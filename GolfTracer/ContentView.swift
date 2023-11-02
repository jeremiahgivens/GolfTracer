//
//  ContentView.swift
//  GolfTracer
//
//  Created by Jeremiah Givens on 11/1/23.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(colors: [.green, .black], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                Form {
                    Section {
                        Button("Select Video"){
                            
                        }
                    }
                    
                    Section {
                        NavigationLink("Crop Video") {
                            Text("this is a new view")
                        }
                        NavigationLink("Trace Time Range") {
                            Text("this is a new view")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Golf Tracer")
        }
    }
}

#Preview {
    ContentView()
}
