//
//  ContentView.swift
//  worthy
//
//  Created by GitHub Copilot
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.pink)
                
                Text("Worthy")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Text("You are more than your money")
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                
                VStack(spacing: 20) {
                    Text("Remember your worth isn't measured by:")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "dollarsign.circle.fill")
                                .foregroundColor(.red)
                            Text("Your bank account")
                        }
                        
                        HStack {
                            Image(systemName: "car.fill")
                                .foregroundColor(.blue)
                            Text("What you own")
                        }
                        
                        HStack {
                            Image(systemName: "building.2.fill")
                                .foregroundColor(.green)
                            Text("Where you work")
                        }
                        
                        HStack {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                            Text("Your achievements")
                        }
                    }
                    .font(.body)
                    .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(15)
                .padding(.horizontal)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Worthy")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}