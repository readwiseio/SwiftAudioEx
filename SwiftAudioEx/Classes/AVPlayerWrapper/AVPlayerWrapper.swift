//
//  AVPlayerWrapper.swift
//  SwiftAudio
//
//  Created by Jørgen Henrichsen on 06/03/2018.
//  Copyright © 2018 Jørgen Henrichsen. All rights reserved.
//

import Foundation
import AVFoundation
import MediaPlayer

public enum PlaybackEndedReason: String {
    case playedUntilEnd
    case playerStopped
    case skippedToNext
    case skippedToPrevious
    case jumpedToIndex
}

public enum StreamResponseError: Error {
    case invalidContentLength
}


class AVPlayerWrapper: NSObject, AVPlayerWrapperProtocol {
    
    struct Constants {
        static let assetPlayableKey = "playable"
    }
    
    // MARK: - Properties
    
    fileprivate var avPlayer = AVPlayer()
    private let playerObserver = AVPlayerObserver()
    internal let playerTimeObserver: AVPlayerTimeObserver
    private let playerItemNotificationObserver = AVPlayerItemNotificationObserver()
    private let playerItemObserver = AVPlayerItemObserver()

    fileprivate var initialTime: TimeInterval?
    fileprivate var pendingAsset: AVAsset? = nil

    /// True when the track was paused for the purpose of switching tracks
    fileprivate var pausedForLoad: Bool = false

    fileprivate let loadingQueue = DispatchQueue(label: "io.readwise.readermobile.loadingQueue")
    
    override public init() {
        playerTimeObserver = AVPlayerTimeObserver(periodicObserverTimeInterval: timeEventFrequency.getTime())
        playerTimeObserver.player = avPlayer

        super.init()

        playerObserver.player = avPlayer
        playerObserver.delegate = self
        playerTimeObserver.delegate = self
        playerItemNotificationObserver.delegate = self
        playerItemObserver.delegate = self

        // disabled since we're not making use of video playback
        avPlayer.allowsExternalPlayback = false;
        
        playerTimeObserver.registerForPeriodicTimeEvents()
    }
    
    // MARK: - AVPlayerWrapperProtocol

    fileprivate(set) var state: AVPlayerWrapperState = AVPlayerWrapperState.idle {
        didSet {
            if oldValue != state {
                delegate?.AVWrapper(didChangeState: state)
            }
        }
    }

    fileprivate(set) var lastPlayerTimeControlStatus: AVPlayer.TimeControlStatus = AVPlayer.TimeControlStatus.paused {
        didSet {
            if oldValue != lastPlayerTimeControlStatus {
                switch lastPlayerTimeControlStatus {
                    case .paused:
                        if pendingAsset == nil {
                            state = .idle
                        }
                        else if currentItem != nil && pausedForLoad != true {
                            state = .paused
                        }
                    case .waitingToPlayAtSpecifiedRate:
                        if pendingAsset != nil {
                            state = .buffering
                        }
                    case .playing:
                        state = .playing
                    @unknown default:
                        break
                }
            }
        }
    }

    /**
     True if the last call to load(from:playWhenReady) had playWhenReady=true.
     */
    fileprivate(set) var playWhenReady: Bool = true
    
    var currentItem: AVPlayerItem? {
        avPlayer.currentItem
    }
    
    var currentTime: TimeInterval {
        let seconds = avPlayer.currentTime().seconds
        return seconds.isNaN ? 0 : seconds
    }
    
    var duration: TimeInterval {
        if let seconds = currentItem?.asset.duration.seconds, !seconds.isNaN {
            return seconds
        }
        else if let seconds = currentItem?.duration.seconds, !seconds.isNaN {
            return seconds
        }
        else if let seconds = currentItem?.seekableTimeRanges.last?.timeRangeValue.duration.seconds,
                !seconds.isNaN {
            return seconds
        }
        return 0.0
    }
    
    var bufferedPosition: TimeInterval {
        currentItem?.loadedTimeRanges.last?.timeRangeValue.end.seconds ?? 0
    }

    var reasonForWaitingToPlay: AVPlayer.WaitingReason? {
        avPlayer.reasonForWaitingToPlay
    }

    var rate: Float {
        get { avPlayer.rate }
        set { avPlayer.rate = newValue }
    }

    weak var delegate: AVPlayerWrapperDelegate? = nil
    
    var bufferDuration: TimeInterval = 0

    var maxBufferDuration: TimeInterval = 20

    var timeEventFrequency: TimeEventFrequency = .everySecond {
        didSet {
            playerTimeObserver.periodicObserverTimeInterval = timeEventFrequency.getTime()
        }
    }
    
    var volume: Float {
        get { avPlayer.volume }
        set { avPlayer.volume = newValue }
    }
    
    var isMuted: Bool {
        get { avPlayer.isMuted }
        set { avPlayer.isMuted = newValue }
    }

    var automaticallyWaitsToMinimizeStalling: Bool {
        get { avPlayer.automaticallyWaitsToMinimizeStalling }
        set { avPlayer.automaticallyWaitsToMinimizeStalling = newValue }
    }
    
    func play() {
        playWhenReady = true
        avPlayer.play()
    }
    
    func pause() {
        playWhenReady = false
        avPlayer.pause()
    }
    
    func togglePlaying() {
        switch avPlayer.timeControlStatus {
        case .playing, .waitingToPlayAtSpecifiedRate:
            pause()
        case .paused:
            play()
        @unknown default:
            fatalError("Unknown AVPlayer.timeControlStatus")
        }
    }
    
    func stop() {
        pause()
        reset(soft: false)
    }
    
    func seek(to seconds: TimeInterval) {
       // if the player is loading then we need to defer seeking until it's ready.
       if (state == AVPlayerWrapperState.loading) {
         initialTime = seconds
       } else {
         avPlayer.seek(to: CMTimeMakeWithSeconds(seconds, preferredTimescale: 1000)) { (finished) in
             if let _ = self.initialTime {
                 self.initialTime = nil
                 if self.playWhenReady {
                     self.play()
                 }
             }
             self.delegate?.AVWrapper(seekTo: Int(seconds), didFinish: finished)
         }
       }
     }
    
    
    
    func load(from url: URL, playWhenReady: Bool, options: [String: Any]? = nil) {
        reset(soft: true)
        self.playWhenReady = playWhenReady

        if currentItem?.status == .failed {
            recreateAVPlayer()
        }

        let urlAsset = AVURLAsset(url: url, options: options)
        urlAsset.resourceLoader.setDelegate(self, queue: self.loadingQueue)
        pendingAsset = urlAsset
        
        if let pendingAsset = pendingAsset {
            state = .loading
            pendingAsset.loadValuesAsynchronously(forKeys: [Constants.assetPlayableKey], completionHandler: { [weak self] in
                guard let self = self else { return }
                
                var error: NSError? = nil
                let status = pendingAsset.statusOfValue(forKey: Constants.assetPlayableKey, error: &error)
                
                DispatchQueue.main.async {
                    if (pendingAsset != self.pendingAsset) { return; }
                    switch status {
                    case .loaded:
                        let item = AVPlayerItem(
                            asset: pendingAsset,
                            automaticallyLoadedAssetKeys: [Constants.assetPlayableKey]
                        )
                        item.preferredForwardBufferDuration = self.bufferDuration
                        self.avPlayer.replaceCurrentItem(with: item)
                        // Register for events
                        self.playerTimeObserver.registerForBoundaryTimeEvents()
                        self.playerObserver.startObserving()
                        self.playerItemNotificationObserver.startObserving(item: item)
                        self.playerItemObserver.startObserving(item: item)

                        if pendingAsset.availableChapterLocales.count > 0 {
                            for locale in pendingAsset.availableChapterLocales {
                                let chapters = pendingAsset.chapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: nil)
                                self.delegate?.AVWrapper(didReceiveMetadata: chapters)
                            }
                        } else {
                            for format in pendingAsset.availableMetadataFormats {
                                let timeRange = CMTimeRange(start: CMTime(seconds: 0, preferredTimescale: 1000), end: pendingAsset.duration)
                                let group = AVTimedMetadataGroup(items: pendingAsset.metadata(forFormat: format), timeRange: timeRange)
                                self.delegate?.AVWrapper(didReceiveMetadata: [group])
                            }
                        }
                        break
                        
                    case .failed:
                        self.reset(soft: false)
                        self.delegate?.AVWrapper(failedWithError: error)
                        break
                        
                    case .cancelled:
                        break
                        
                    default:
                        break
                    }
                }
            })
        }
    }
    
    func load(from url: URL, playWhenReady: Bool, initialTime: TimeInterval? = nil, options: [String : Any]? = nil) {
        self.initialTime = initialTime

        pausedForLoad = true
        pause()

        self.load(from: url, playWhenReady: playWhenReady, options: options)
    }
    
    // MARK: - Util
    
    private func reset(soft: Bool) {
        playerItemObserver.stopObservingCurrentItem()
        playerTimeObserver.unregisterForBoundaryTimeEvents()
        playerItemNotificationObserver.stopObservingCurrentItem()

        pendingAsset?.cancelLoading()
        pendingAsset = nil
        
        if !soft {
            avPlayer.replaceCurrentItem(with: nil)
        }
    }
    
    /// Will recreate the AVPlayer instance. Used when the current one fails.
    private func recreateAVPlayer() {
        let player = AVPlayer()
        playerObserver.player = player
        playerTimeObserver.player = player
        playerTimeObserver.registerForPeriodicTimeEvents()
        avPlayer = player
        delegate?.AVWrapperDidRecreateAVPlayer()
    }
    
}

extension AVPlayerWrapper: AVPlayerObserverDelegate {
    
    // MARK: - AVPlayerObserverDelegate
    
    func player(didChangeTimeControlStatus status: AVPlayer.TimeControlStatus) {
        lastPlayerTimeControlStatus = status;
    }
    
    func player(statusDidChange status: AVPlayer.Status) {
        switch status {
        case .readyToPlay:
            state = .ready
            pausedForLoad = false
            if playWhenReady && (initialTime ?? 0) == 0 {
                play()
            }
            else if let initialTime = initialTime {
                seek(to: initialTime)
            }
            break
            
        case .failed:
            delegate?.AVWrapper(failedWithError: avPlayer.error)
            break
            
        case .unknown:
            break
        @unknown default:
            break
        }
    }
}

extension AVPlayerWrapper: AVPlayerTimeObserverDelegate {
    
    // MARK: - AVPlayerTimeObserverDelegate
    
    func audioDidStart() {
        state = .playing
    }
    
    func timeEvent(time: CMTime) {
        delegate?.AVWrapper(secondsElapsed: time.seconds)
    }
    
}

extension AVPlayerWrapper: AVPlayerItemNotificationObserverDelegate {
    
    // MARK: - AVPlayerItemNotificationObserverDelegate
    
    func itemDidPlayToEndTime() {
        delegate?.AVWrapperItemDidPlayToEndTime()
    }
    
}

extension AVPlayerWrapper: AVPlayerItemObserverDelegate {
    
    // MARK: - AVPlayerItemObserverDelegate
    
    func item(didUpdateDuration duration: Double) {
        delegate?.AVWrapper(didUpdateDuration: duration)
    }
    
    func item(didReceiveMetadata metadata: [AVTimedMetadataGroup]) {
        delegate?.AVWrapper(didReceiveMetadata: metadata)
    }
    
}

extension AVPlayerWrapper: AVAssetResourceLoaderDelegate {
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        // Revert custom URL scheme used to trigger this delegate call
        var components = URLComponents(url: loadingRequest.request.url!, resolvingAgainstBaseURL: false)!
        components.scheme = "https"
        var request = URLRequest(url: components.url!)
        // Copy all headers, including authentication header
        request.allHTTPHeaderFields = loadingRequest.request.allHTTPHeaderFields
        // Test whether this is a real request for stream data
        if loadingRequest.contentInformationRequest == nil, let dataRequest = loadingRequest.dataRequest {
            let start = dataRequest.requestedOffset
            var end = start + Int64(dataRequest.requestedLength) - 1 // Range header byte range is inclusive of end
            var bitrate = self.currentItem?.accessLog()?.events.last?.indicatedBitrate ?? -1
            if bitrate == -1 {
                bitrate = 48_000
            }
            let forwardBufferLength = Int64(self.maxBufferDuration * bitrate / 8)
            let maxEnd = Int64(self.currentTime * bitrate / 8) + forwardBufferLength
            if end > maxEnd {
                end = maxEnd
            }
            if end <= start {
                // We're requesting zero bytes, so we are probably paused
                print("resourceLoader: Skipping request for zero bytes")
                self.loadingQueue.asyncAfter(deadline: .now() + 1.0, execute: {
                    loadingRequest.finishLoading()
                })
                return true
            }
            // Overwrite Range header with custom header
            let newRangeHeader = "bytes=\(start)-\(end)"
            request.setValue(newRangeHeader, forHTTPHeaderField: "Range")
            print("resourceLoader: Requesting data from \(request), rewrote Range: \(request.allHTTPHeaderFields!["Range"]!)")
        }
        // Fire the modified request
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            self.loadingQueue.async {
                if error != nil {
                    loadingRequest.finishLoading(with: error)
                    return
                }
                let response = response! as! HTTPURLResponse
                if let contentInfo = loadingRequest.contentInformationRequest {
                    // Fill contentInfo with stream metadata, most notably the length of the entire stream
                    let contentRange = response.allHeaderFields["content-range"] as? String
                    // Content-Range looks like "bytes=0-1000/2000" where "2000" is the total stream length in bytes
                    guard let contentLengthString = contentRange?.split(separator: "/")[1] else {
                        loadingRequest.finishLoading(with: StreamResponseError.invalidContentLength)
                        return
                    }
                    guard let contentLength = Int64(contentLengthString) else {
                        loadingRequest.finishLoading(with: StreamResponseError.invalidContentLength)
                        return
                    }
                    contentInfo.contentLength = contentLength
                    contentInfo.contentType = "public.mp3"
                    contentInfo.isByteRangeAccessSupported = true
                    print("resourceLoader: Filling contentInfo, contentLength=\(contentLength) bytes")
                    loadingRequest.finishLoading()
                } else if let dataRequest = loadingRequest.dataRequest {
                    // This was a real request for stream data, so just pipe the data through
                    print("resourceLoader: Received \(data!.count) bytes of audio data")
                    dataRequest.respond(with: data!)
                    // Delay the next request by a second to not overload the server
                    self.loadingQueue.asyncAfter(deadline: .now() + 1.0, execute: {
                        loadingRequest.finishLoading()
                    })
                }
            }
        }
        task.resume()
        return true // meaning "the delegate (we) will handle the request"
    }
}
