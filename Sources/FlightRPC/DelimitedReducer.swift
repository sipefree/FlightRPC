//
//  File.swift
//  
//
//  Created by Simon Free on 2020-03-07.
//

import Foundation
import Combine

extension Publisher {
    
    public func delimitedReduce<Result>(
        into initialResult: @escaping @autoclosure () -> Result,
        isDelimiter: @escaping (Self.Output) -> Bool,
        updateResult: @escaping (inout Result, Self.Output) -> Void,
        waitForFirstDelimiter: Bool = false
    ) -> Publishers.DelimitedReducer<Self, Result> {
        .init(
            upstream: self,
            initialResult: initialResult,
            isDelimiter: isDelimiter,
            updateResult: updateResult,
            waitForFirstDelimiter: waitForFirstDelimiter
        )
    }
    
    public func delimitedReduce<Result>(
        _ initialResult: @escaping @autoclosure () -> Result,
        isDelimiter: @escaping (Self.Output) -> Bool,
        nextResult: @escaping (Result, Self.Output) -> Result,
        waitForFirstDelimiter: Bool = false
    ) -> Publishers.DelimitedReducer<Self, Result> {
        .init(
            upstream: self,
            initialResult: initialResult,
            isDelimiter: isDelimiter,
            nextResult: nextResult,
            waitForFirstDelimiter: waitForFirstDelimiter
        )
    }
    
}

extension Publishers {
    
    public struct DelimitedReducer<Upstream: Publisher, Output>: Publisher {
        
        public typealias Input = Upstream.Output
        public typealias Output = Output
        public typealias Failure = Upstream.Failure
        
        public init(
            upstream: Upstream,
            initialResult: @escaping () -> Output,
            isDelimiter: @escaping (Input) -> Bool,
            updateResult: @escaping (inout Output, Input) -> Void,
            waitForFirstDelimiter: Bool = false
        ) {
            self.upstream = upstream
            self.initialResult = initialResult
            self.isDelimiter = isDelimiter
            self.updateResult = updateResult
            self.waitForFirstDelimiter = waitForFirstDelimiter
        }
        
        public init(
            upstream: Upstream,
            initialResult: @escaping () -> Output,
            isDelimiter: @escaping (Input) -> Bool,
            nextResult: @escaping (Output, Input) -> Output,
            waitForFirstDelimiter: Bool = false
        ) {
            self.init(
                upstream: upstream,
                initialResult: initialResult,
                isDelimiter: isDelimiter,
                updateResult: { (output, input) in
                    output = nextResult(output, input)
                },
                waitForFirstDelimiter: waitForFirstDelimiter
            )
        }
        
        private let upstream: Upstream
        
        private let initialResult: () -> Output
        
        private let isDelimiter: (Input) -> Bool
        
        private let updateResult: (inout Output, Input) -> Void
        
        private let waitForFirstDelimiter: Bool
        
        public func receive<S>(subscriber: S)
        where
            S : Subscriber,
            Self.Failure == S.Failure,
            Self.Output == S.Input
        {
            let inner = Inner(
                downstream: subscriber,
                initialResult: initialResult,
                isDelimiter: isDelimiter,
                updateResult: updateResult,
                waitForFirstDelimiter: waitForFirstDelimiter
            )
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
            
            private let downstream: Downstream
            
            private let initialResult: () -> Output
            
            private let isDelimiter: (Input) -> Bool
            
            private let updateResult: (inout Output, Input) -> Void
            
            private var state: State
            
            private var subscription: Subscription?
            
            private var remainingDemand: Demand = .max(0)
            
            init(
                downstream: Downstream,
                initialResult: @escaping () -> Output,
                isDelimiter: @escaping (Input) -> Bool,
                updateResult: @escaping (inout Output, Input) -> Void,
                waitForFirstDelimiter: Bool
            ) {
                self.downstream = downstream
                self.initialResult = initialResult
                self.isDelimiter = isDelimiter
                self.updateResult = updateResult
                
                if waitForFirstDelimiter {
                    self.state = .awaitingFirstEnd
                } else {
                    self.state = .collecting(initialResult())
                }
            }
            
            private enum State {
                case awaitingFirstEnd
                case collecting(Output)
                case fullOutput(Output)
            }
            
            private func sendOutput(_ output: Output) {
                let demand = downstream.receive(output)
                if remainingDemand < .unlimited {
                    remainingDemand += (demand - 1)
                }
                state = .collecting(initialResult())
            }
            
            func receive(subscription: Subscription) {
                self.subscription = subscription
                subscription.request(.unlimited)
            }
            
            func receive(_ input: Input) -> Demand {
                switch (isDelimiter(input), remainingDemand, state) {
                    
                case (true, _, .awaitingFirstEnd):
                    state = .collecting(initialResult())
                    
                case (true, .none, .collecting(let output)):
                    state = .fullOutput(output)
                    subscription?.request(.max(0))
                    
                case (true, _, .collecting(let output)):
                    sendOutput(output)
                    
                case (false, _, .collecting(var output)):
                    updateResult(&output, input)
                    state = .collecting(output)
                    
                case (_, _, .fullOutput), (false, _, .awaitingFirstEnd):
                    break
                    
                }
                
                return .max(0)
            }
             
            func receive(completion: Subscribers.Completion<Upstream.Failure>) {
                downstream.receive(completion: completion)
            }
            
            func request(_ demand: Subscribers.Demand) {
                remainingDemand = demand
                
                if remainingDemand > .max(0), case .fullOutput(let output) = state {
                    subscription?.request(.unlimited)
                    sendOutput(output)
                }
            }
            
            func cancel() {
                subscription?.cancel()
                subscription = nil
            }
            
        }
    }
        
    
}


