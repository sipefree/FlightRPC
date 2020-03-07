//
//  File.swift
//  
//
//  Created by Simon Free on 2020-03-07.
//

import Foundation
import Combine

extension Publishers {
    
    public struct DelimitedReducer<Upstream: Publisher, Output>: Publisher {
        
        public typealias Input = Upstream.Output
        public typealias Output = Output
        public typealias Failure = Upstream.Failure
        
        public init(
            upstream: Upstream,
            initalResult: @escaping () -> Output,
            isDelimiter: @escaping (Input) -> Bool,
            updateResult: @escaping (inout Output, Input) -> Void,
            waitForFirstEnd: Bool = false
        ) {
            self.upstream = upstream
            self.makeInitialResult = initalResult
            self.isDelimiter = isDelimiter
            self.updateResult = updateResult
            self.waitForFirstEnd = waitForFirstEnd
        }
        
        public init(
            upstream: Upstream,
            initalResult: @escaping () -> Output,
            isDelimiter: @escaping (Input) -> Bool,
            nextResult: @escaping (Output, Input) -> Output,
            waitForFirstEnd: Bool = false
        ) {
            self.init(
                upstream: upstream,
                initalResult: initialResult,
                isDelimiter: isDelimiter,
                updateResult: { (output, input) -> Bool in
                    guard let next = nextResult(output, input) else { return false }
                    output = next
                },
                waitForFirstEnd: waitForFirstEnd
            )
        }
        
        private let upstream: Upstream
        
        private let makeInitialResult: () -> Output
        
        private let isDelimiter: (Input) -> Bool
        
        private let updateResult: (inout Output, Input) -> Bool
        
        private let waitForFirstEnd: Bool
        
        func receive<S>(subscriber: S)
        where
            S : Subscriber,
            Self.Failure == S.Failure,
            Self.Output == S.Input
        {
            let inner = Inner(downstream: subscriber)
            upstream.subscribe(inner)
            subscriber.receive(subscription: inner)
        }
        
        private final class Inner<Downstream: Subscriber, Output>:
            Subscriber,
            Subscription
        where
            Downstream.Input == Output,
            Downstream.Failure == Upstream.Failure
        {
            typealias Input = Upstream.Output
            typealias Failure = Upstream.Failure
            typealias Demand = Subscribers.Demand
            
            private let makeInitialResult: () -> Output
            
            private let isDelimiter: (Input) -> Bool
            
            private let updateResult: (inout Output, Input) -> Bool
            
            private var state: State
            
            private var subscription: Subscription?
            
            private var remainingDemand: Demand = .max(0)
            
            init(
                downstream: Downstream,
                initalResult: @escaping () -> Output,
                isDelimiter: @escaping (Input) -> Bool,
                updateResult: @escaping (inout Output, Input) -> Bool,
                waitForFirstEnd: Bool
            ) {
                self.downstream = downstream
                self.makeInitialResult = initialResult
                self.isDelimiter = isDelimiter
                self.updateResult = updateResult
                self.output = initialResult()
                
                if waitForFirstEnd {
                    self.state = .awaitingFirstEnd
                } else {
                    self.state = .collecting
                }
            }
            
            private enum State {
                case awaitingFirstEnd
                case collecting(Output)
                case fullOutput(Output)
                
                var upstreamDemand: Demand {
                    if case .fullOutput = self {
                        return .max(0)
                    } else {
                        return .unlimited
                    }
                }
            }
            
            private func sendOutput(_ output: Output) {
                let demand = downstream.receive(output)
                remainingDemand += (demand - 1)
                state = .collecting(makeInitialResult())
            }
            
            func receive(subscription: Subscription) {
                self.subscription = subscription
                subscription.request(state.upstreamDemand)
            }
            
            func receive(_ input: Input) -> Demand {
                switch (isDelimiter(input), state) {
                case (true, .awaitingFirstEnd):
                    state = .collecting
                    
                }
                
                return state.upstreamDemand
            }
            
            
            
        }
    }
        
    
}
