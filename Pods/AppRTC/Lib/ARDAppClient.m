/*
 * libjingle
 * Copyright 2014, Google Inc.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *  1. Redistributions of source code must retain the above copyright notice,
 *     this list of conditions and the following disclaimer.
 *  2. Redistributions in binary form must reproduce the above copyright notice,
 *     this list of conditions and the following disclaimer in the documentation
 *     and/or other materials provided with the distribution.
 *  3. The name of the author may not be used to endorse or promote products
 *     derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 * EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "ARDAppClient.h"

#import <AVFoundation/AVFoundation.h>

#import "ARDMessageResponse.h"
#import "ARDRegisterResponse.h"
#import "ARDSignalingMessage.h"
#import "ARDUtilities.h"
#import "ARDWebSocketChannel.h"
#import "RTCICECandidate+JSON.h"
#import "RTCICEServer+JSON.h"
#import "RTCMediaConstraints.h"
#import "RTCMediaStream.h"
#import "RTCPair.h"
#import "RTCPeerConnection.h"
#import "RTCPeerConnectionDelegate.h"
#import "RTCPeerConnectionFactory.h"
#import "RTCSessionDescription+JSON.h"
#import "RTCSessionDescriptionDelegate.h"
#import "RTCVideoCapturer.h"
#import "RTCVideoTrack.h"


// TODO(tkchin): move these to a configuration object.
static NSString *kARDRoomServerHostUrl =
    @"https://apprtc.appspot.com";
static NSString *kARDRoomServerRegisterFormat =
    @"%@/join/%@";
static NSString *kARDRoomServerMessageFormat =
    @"%@/message/%@/%@";
static NSString *kARDRoomServerByeFormat =
    @"%@/leave/%@/%@";

static NSString *kARDDefaultSTUNServerUrl =
    @"stun:stun.l.google.com:19302";
// TODO(tkchin): figure out a better username for CEOD statistics.
static NSString *kARDTurnRequestUrl =
    @"https://computeengineondemand.appspot.com"
    @"/turn?username=iapprtc&key=4080218913";

static NSString *kARDAppClientErrorDomain = @"ARDAppClient";
static NSInteger kARDAppClientErrorUnknown = -1;
static NSInteger kARDAppClientErrorRoomFull = -2;
static NSInteger kARDAppClientErrorCreateSDP = -3;
static NSInteger kARDAppClientErrorSetSDP = -4;
static NSInteger kARDAppClientErrorNetwork = -5;
static NSInteger kARDAppClientErrorInvalidClient = -6;
static NSInteger kARDAppClientErrorInvalidRoom = -7;

@interface ARDAppClient () <ARDWebSocketChannelDelegate,
    RTCPeerConnectionDelegate, RTCSessionDescriptionDelegate, RTCDataChannelDelegate>
@property(nonatomic, strong) ARDWebSocketChannel *channel;
@property(nonatomic, strong) RTCPeerConnection *peerConnection;
@property(nonatomic, strong) RTCDataChannel *dataChannel;
@property(nonatomic, strong) RTCPeerConnectionFactory *factory;
@property(nonatomic, strong) NSMutableArray *messageQueue;

@property(nonatomic, assign) BOOL isTurnComplete;
@property(nonatomic, assign) BOOL hasReceivedSdp;
@property(nonatomic, readonly) BOOL isRegisteredWithRoomServer;

@property(nonatomic, strong) NSString *roomId;
@property(nonatomic, strong) NSString *clientId;
@property(nonatomic, assign) BOOL isInitiator;
@property(nonatomic, strong) NSMutableArray *iceServers;
@property(nonatomic, strong) NSURL *webSocketURL;
@property(nonatomic, strong) NSURL *webSocketRestURL;

@property(nonatomic, assign) BOOL isToggle;
@end

@implementation ARDAppClient

@synthesize delegate = _delegate;
@synthesize state = _state;
@synthesize serverHostUrl = _serverHostUrl;
@synthesize channel = _channel;
@synthesize peerConnection = _peerConnection;
@synthesize dataChannel = _dataChannel;
@synthesize factory = _factory;
@synthesize messageQueue = _messageQueue;
@synthesize isTurnComplete = _isTurnComplete;
@synthesize hasReceivedSdp  = _hasReceivedSdp;
@synthesize roomId = _roomId;
@synthesize clientId = _clientId;
@synthesize isInitiator = _isInitiator;
@synthesize iceServers = _iceServers;
@synthesize webSocketURL = _websocketURL;
@synthesize webSocketRestURL = _websocketRestURL;

- (instancetype)initWithDelegate:(id<ARDAppClientDelegate>)delegate {
  if (self = [super init]) {
    _delegate = delegate;
    _factory = [[RTCPeerConnectionFactory alloc] init];
    _messageQueue = [NSMutableArray array];
    _iceServers = [NSMutableArray arrayWithObject:[self defaultSTUNServer]];
    _serverHostUrl = kARDRoomServerHostUrl;
      
      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(orientationChanged:)
                                                   name:@"UIDeviceOrientationDidChangeNotification"
                                                 object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self name:@"UIDeviceOrientationDidChangeNotification" object:nil];
  [self disconnect];
}

- (void)orientationChanged:(NSNotification *)notification {
    UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
    if (UIDeviceOrientationIsLandscape(orientation) || UIDeviceOrientationIsPortrait(orientation)) {
        //Remove current video track
        RTCMediaStream *localStream = _peerConnection.localStreams[0];
        [localStream removeVideoTrack:localStream.videoTracks[0]];
        
        RTCVideoTrack *localVideoTrack = [self createLocalVideoTrack];
        if (localVideoTrack) {
            [localStream addVideoTrack:localVideoTrack];
            [_delegate appClient:self didReceiveLocalVideoTrack:localVideoTrack];
        }
        [_peerConnection removeStream:localStream];
        [_peerConnection addStream:localStream];
    }
}


- (void)setState:(ARDAppClientState)state {
  if (_state == state) {
    return;
  }
  _state = state;
  [_delegate appClient:self didChangeState:_state];
}

- (void)connectToRoomWithId:(NSString *)roomId
                    options:(NSDictionary *)options {
  NSParameterAssert(roomId.length);
  NSParameterAssert(_state == kARDAppClientStateDisconnected);
  self.state = kARDAppClientStateConnecting;

  // Request TURN.
  __weak ARDAppClient *weakSelf = self;
  NSURL *turnRequestURL = [NSURL URLWithString:kARDTurnRequestUrl];
  [self requestTURNServersWithURL:turnRequestURL
                completionHandler:^(NSArray *turnServers) {
    ARDAppClient *strongSelf = weakSelf;
    [strongSelf.iceServers addObjectsFromArray:turnServers];
    strongSelf.isTurnComplete = YES;
    [strongSelf startSignalingIfReady];
  }];

  // Register with room server.
  [self registerWithRoomServerForRoomId:roomId
                      completionHandler:^(ARDRegisterResponse *response) {
    ARDAppClient *strongSelf = weakSelf;
    if (!response || response.result != kARDRegisterResultTypeSuccess) {
      NSLog(@"Failed to register with room server. Result:%d",
          (int)response.result);
      [strongSelf disconnect];
      NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"Room is full.",
      };
      NSError *error =
          [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                     code:kARDAppClientErrorRoomFull
                                 userInfo:userInfo];
      [strongSelf.delegate appClient:strongSelf didError:error];
      return;
    }
    NSLog(@"Registered with room server.");
    strongSelf.roomId = response.roomId;
    strongSelf.clientId = response.clientId;
    strongSelf.isInitiator = response.isInitiator;
    for (ARDSignalingMessage *message in response.messages) {
      if (message.type == kARDSignalingMessageTypeOffer ||
          message.type == kARDSignalingMessageTypeAnswer) {
        strongSelf.hasReceivedSdp = YES;
        [strongSelf.messageQueue insertObject:message atIndex:0];
      } else {
        [strongSelf.messageQueue addObject:message];
      }
    }
    strongSelf.webSocketURL = response.webSocketURL;
    strongSelf.webSocketRestURL = response.webSocketRestURL;
    [strongSelf registerWithColliderIfReady];
    [strongSelf startSignalingIfReady];
  }];
}

- (void)disconnect {
  if (_state == kARDAppClientStateDisconnected) {
    return;
  }
  if (self.isRegisteredWithRoomServer) {
    [self unregisterWithRoomServer];
  }
  if (_channel) {
    if (_channel.state == kARDWebSocketChannelStateRegistered) {
      // Tell the other client we're hanging up.
      ARDByeMessage *byeMessage = [[ARDByeMessage alloc] init];
      NSData *byeData = [byeMessage JSONData];
      [_channel sendData:byeData];
    }
    // Disconnect from collider.
    _channel = nil;
  }
  _clientId = nil;
  _roomId = nil;
  _isInitiator = NO;
  _hasReceivedSdp = NO;
  _messageQueue = [NSMutableArray array];
  _peerConnection = nil;
  self.state = kARDAppClientStateDisconnected;
}

- (BOOL)isActive
{
    return (_dataChannel && (_dataChannel.state == kRTCDataChannelStateOpen));
}

- (void)sendMessage:(UIImage*)imageToSend {
    if ([self isActive])
    {
        //-----------
        UIImage * thumbnail = nil;
        if(self.isToggle){
            //NSData *sendingData = UIImagePNGRepresentation([UIImage imageNamed:@"test.PNG"]);
            thumbnail = [UIImage imageNamed: @"test2.PNG"];
            self.isToggle = NO;
        }else{
            thumbnail = [UIImage imageNamed: @"old.png"];
            self.isToggle = YES;
        }
        //NSData *imagedata = UIImagePNGRepresentation(imageToSend);
        NSData *imagedata = UIImageJPEGRepresentation(imageToSend, 0.8f);
        NSUInteger imageDataLength = [imagedata length];
        //-----------
        
        
        NSError *error;
        int tempInt = imageDataLength;
        NSDictionary *messageDict = @{@"message": [NSString stringWithFormat:@"%d",tempInt]};
        NSData *messageData = [NSJSONSerialization dataWithJSONObject:messageDict options:0 error:&error];
        if (!error)
        {
            RTCDataBuffer *data = [[RTCDataBuffer alloc] initWithData:messageData isBinary:NO];
            //RTCDataBuffer *data = [[RTCDataBuffer alloc] initWithData:imagedata isBinary:NO];
            if ([_dataChannel sendData:data])
            {
                //successHandler();
                int a = 0;
            }
            else
            {
                //errorHandler(@"Message failed to send");
            }
        }
        else
        {
            //errorHandler(@"Unable to encode message to JSON");
        }

        
       // NSDictionary *messageDict = @{@"message": message};
       // NSData *messageData = [NSJSONSerialization dataWithJSONObject:messageDict options:0 error:&error];
        
        NSUInteger chunkSize = 12 * 1024;
        NSUInteger offset = 0;
        do {
            NSUInteger thisChunkSize = imageDataLength - offset > chunkSize ? chunkSize : imageDataLength - offset;
            NSData* chunk = [NSData dataWithBytesNoCopy:(char *)[imagedata bytes] + offset
                                                 length:thisChunkSize
                                           freeWhenDone:NO];
            NSLog(@"chunk length : %lu",(unsigned long)chunk.length);
            RTCDataBuffer *data = [[RTCDataBuffer alloc] initWithData:[NSData dataWithData:chunk] isBinary:NO];
            if ([_dataChannel sendData:data])
            {
                //successHandler();
                int a = 0;
            }
            else
            {
                //errorHandler(@"Message failed to send");
            }
            //[marrFileData addObject:[NSData dataWithData:chunk]];
            offset += thisChunkSize;
        } while (offset < imageDataLength);
        
    
        //if (!error)
        //{
            //RTCDataBuffer *data = [[RTCDataBuffer alloc] initWithData:messageData isBinary:NO];
        
        //}
        //else
        //{
            //errorHandler(@"Unable to encode message to JSON");
       // }
        
       /* NSData *sendData = UIImagePNGRepresentation([UIImage imageNamed:@"test2.PNG"]);
        NSUInteger length = [sendData length];
        NSUInteger chunkSize = 100 * 1024;
        NSUInteger offset = 0;
        do {
            NSUInteger thisChunkSize = length - offset > chunkSize ? chunkSize : length - offset;
            NSData* chunk = [NSData dataWithBytesNoCopy:(char *)[sendData bytes] + offset
                                                 length:thisChunkSize
                                           freeWhenDone:NO];
            NSLog(@"chunk length : %lu",(unsigned long)chunk.length);
            
            [marrFileData addObject:[NSData dataWithData:chunk]];
            offset += thisChunkSize;
        } while (offset < length);*/
        
    }
    else
    {
        //errorHandler(@"dataChannel not in an open state.");
    }
}

#pragma mark - ARDWebSocketChannelDelegate

- (void)channel:(ARDWebSocketChannel *)channel
    didReceiveMessage:(ARDSignalingMessage *)message {
  switch (message.type) {
    case kARDSignalingMessageTypeOffer:
    case kARDSignalingMessageTypeAnswer:
      _hasReceivedSdp = YES;
      [_messageQueue insertObject:message atIndex:0];
      break;
    case kARDSignalingMessageTypeCandidate:
      [_messageQueue addObject:message];
      break;
    case kARDSignalingMessageTypeBye:
      [self processSignalingMessage:message];
      return;
  }
  [self drainMessageQueueIfReady];
}

- (void)channel:(ARDWebSocketChannel *)channel
    didChangeState:(ARDWebSocketChannelState)state {
  switch (state) {
    case kARDWebSocketChannelStateOpen:
      break;
    case kARDWebSocketChannelStateRegistered:
      break;
    case kARDWebSocketChannelStateClosed:
    case kARDWebSocketChannelStateError:
      // TODO(tkchin): reconnection scenarios. Right now we just disconnect
      // completely if the websocket connection fails.
      [self disconnect];
      break;
  }
}

#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    signalingStateChanged:(RTCSignalingState)stateChanged {
  NSLog(@"Signaling state changed: %d", stateChanged);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
           addedStream:(RTCMediaStream *)stream {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"Received %lu video tracks and %lu audio tracks",
        (unsigned long)stream.videoTracks.count,
        (unsigned long)stream.audioTracks.count);
    if (stream.videoTracks.count) {
      RTCVideoTrack *videoTrack = stream.videoTracks[0];
      [_delegate appClient:self didReceiveRemoteVideoTrack:videoTrack];
    }
  });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
        removedStream:(RTCMediaStream *)stream {
  NSLog(@"Stream was removed.");
}

- (void)peerConnectionOnRenegotiationNeeded:
    (RTCPeerConnection *)peerConnection {
  NSLog(@"WARNING: Renegotiation needed but unimplemented.");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    iceConnectionChanged:(RTCICEConnectionState)newState {
  NSLog(@"ICE state changed: %d", newState);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    iceGatheringChanged:(RTCICEGatheringState)newState {
  NSLog(@"ICE gathering state changed: %d", newState);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
       gotICECandidate:(RTCICECandidate *)candidate {
  dispatch_async(dispatch_get_main_queue(), ^{
    ARDICECandidateMessage *message =
        [[ARDICECandidateMessage alloc] initWithCandidate:candidate];
    [self sendSignalingMessage:message];
  });
}

- (void)peerConnection:(RTCPeerConnection*)peerConnection
    didOpenDataChannel:(RTCDataChannel*)newDataChannel {
    if (_dataChannel)
    {
        // Replacing the previous connection, so disable delegate messages from the old instance
        _dataChannel.delegate = nil;
    }
    else
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            //Respoke
             // This callback will not be called in this test. It is only triggered when adding a directConnection to an existing call, which is currently not supported.
          //  [self.delegate onStart:self];
        });
    }
    
    _dataChannel = newDataChannel;
    _dataChannel.delegate = self;
}

#pragma mark - RTCSessionDescriptionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didCreateSessionDescription:(RTCSessionDescription *)sdp
                          error:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (error) {
      NSLog(@"Failed to create session description. Error: %@", error);
      [self disconnect];
      NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"Failed to create session description.",
      };
      NSError *sdpError =
          [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                     code:kARDAppClientErrorCreateSDP
                                 userInfo:userInfo];
      [_delegate appClient:self didError:sdpError];
      return;
    }
    [_peerConnection setLocalDescriptionWithDelegate:self
                                  sessionDescription:sdp];
    ARDSessionDescriptionMessage *message =
        [[ARDSessionDescriptionMessage alloc] initWithDescription:sdp];
    [self sendSignalingMessage:message];
  });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
    didSetSessionDescriptionWithError:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (error) {
      NSLog(@"Failed to set session description. Error: %@", error);
      [self disconnect];
      NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: @"Failed to set session description.",
      };
      NSError *sdpError =
          [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                     code:kARDAppClientErrorSetSDP
                                 userInfo:userInfo];
      [_delegate appClient:self didError:sdpError];
      return;
    }
    // If we're answering and we've just set the remote offer we need to create
    // an answer and set the local description.
    if (!_isInitiator && !_peerConnection.localDescription) {
      RTCMediaConstraints *constraints = [self defaultAnswerConstraints];
      [_peerConnection createAnswerWithDelegate:self
                                    constraints:constraints];

    }
  });
}

#pragma mark - RTCDataChannelDelegate
// Called when the data channel state has changed.
- (void)channelDidChangeState:(RTCDataChannel*)channel {
    switch (channel.state)
    {
        case kRTCDataChannelStateConnecting:
            NSLog(@"Direct connection CONNECTING");
            break;
            
        case kRTCDataChannelStateOpen:
        {
            NSLog(@"Direct connection OPEN");
            //[call directConnectionDidOpen:self];
            dispatch_async(dispatch_get_main_queue(), ^{
                //[self.delegate onOpen:self];
            });
        }
            break;
            
        case kRTCDataChannelStateClosing:
            NSLog(@"Direct connection CLOSING");
            break;
            
        case kRTCDataChannelStateClosed:
        {
            NSLog(@"Direct connection CLOSED");
            _dataChannel = nil;
            //[call directConnectionDidClose:self];
            dispatch_async(dispatch_get_main_queue(), ^{
                //[self.delegate onClose:self];
            });
        }
            break;
    }
}

// Called when a data buffer was successfully received.
- (void)channel:(RTCDataChannel*)channel
didReceiveMessageWithBuffer:(RTCDataBuffer*)buffer {
    [_delegate appClient:self rtcDataChannel:channel didReceiveRCTDataBufer:buffer];
//    id message = nil;
//    NSError *error;
//    
//    NSData *temp = buffer.data;
//    NSString* str = [[NSString alloc] initWithData:temp
//                                           encoding:NSUTF8StringEncoding];
//    
//    
//    if (str && [str length] > 0){
//        NSLog(@"Contains string");
//    }else{
//        NSLog(@"Does't contains string");
//        
//    }
//    
//    id jsonResult = [NSJSONSerialization JSONObjectWithData:buffer.data options:0 error:&error];
//    if (error)
//    {
//        // Could not parse JSON data, so just pass it as it is
//        message = buffer.data;
//        NSLog(@"Direct Message received (binary)");
//        dispatch_async(dispatch_get_main_queue(), ^{
//            //[self.delegate onMessage:message sender:self];
//        });
//    }
//    else
//    {
//        if (jsonResult && ([jsonResult isKindOfClass:[NSDictionary class]]))
//        {
//            NSDictionary *dict = (NSDictionary*)jsonResult;
//            NSString *messageText = [dict objectForKey:@"message"];
//            
//            if (messageText)
//            {
//                NSLog(@"Direct Message received: [%@]", messageText);
//                dispatch_async(dispatch_get_main_queue(), ^{
//                    //[self.delegate onMessage:messageText sender:self];
//                });
//            }
//        }
//    }

}

#pragma mark - Private

- (BOOL)isRegisteredWithRoomServer {
  return _clientId.length;
}

- (void)startSignalingIfReady {
  if (!_isTurnComplete || !self.isRegisteredWithRoomServer) {
    return;
  }
  self.state = kARDAppClientStateConnected;

  // Create peer connection.
  RTCMediaConstraints *constraints = [self defaultPeerConnectionConstraints];
  _peerConnection = [_factory peerConnectionWithICEServers:_iceServers
                                               constraints:constraints
                                                  delegate:self];
  //RTCMediaStream *localStream = [self createLocalMediaStream];
  //[_peerConnection addStream:localStream];
  if (_isInitiator) {
      
      //Create data channel
      RTCDataChannelInit *initData = [[RTCDataChannelInit alloc] init];
      _dataChannel = [_peerConnection createDataChannelWithLabel:@"BoardPACDataChannel" config:initData];
      _dataChannel.delegate = self;
      
    [self sendOffer];
  } else {
    [self waitForAnswer];
      
      
  }
}

- (void)sendOffer {
  [_peerConnection createOfferWithDelegate:self
                               constraints:[self defaultOfferConstraints]];
}

- (void)waitForAnswer {
  [self drainMessageQueueIfReady];
}

- (void)drainMessageQueueIfReady {
  if (!_peerConnection || !_hasReceivedSdp) {
    return;
  }
  for (ARDSignalingMessage *message in _messageQueue) {
    [self processSignalingMessage:message];
  }
  [_messageQueue removeAllObjects];
}

- (void)processSignalingMessage:(ARDSignalingMessage *)message {
  NSParameterAssert(_peerConnection ||
      message.type == kARDSignalingMessageTypeBye);
  switch (message.type) {
    case kARDSignalingMessageTypeOffer:
    case kARDSignalingMessageTypeAnswer: {
      ARDSessionDescriptionMessage *sdpMessage =
          (ARDSessionDescriptionMessage *)message;
      RTCSessionDescription *description = sdpMessage.sessionDescription;
      [_peerConnection setRemoteDescriptionWithDelegate:self
                                     sessionDescription:description];
      break;
    }
    case kARDSignalingMessageTypeCandidate: {
      ARDICECandidateMessage *candidateMessage =
          (ARDICECandidateMessage *)message;
      [_peerConnection addICECandidate:candidateMessage.candidate];
      break;
    }
    case kARDSignalingMessageTypeBye:
      // Other client disconnected.
      // TODO(tkchin): support waiting in room for next client. For now just
      // disconnect.
      [self disconnect];
      break;
  }
}

- (void)sendSignalingMessage:(ARDSignalingMessage *)message {
  if (_isInitiator) {
    [self sendSignalingMessageToRoomServer:message completionHandler:nil];
  } else {
    [self sendSignalingMessageToCollider:message];
  }
}


- (RTCVideoTrack *)createLocalVideoTrack {
    // The iOS simulator doesn't provide any sort of camera capture
    // support or emulation (http://goo.gl/rHAnC1) so don't bother
    // trying to open a local stream.
    // TODO(tkchin): local video capture for OSX. See
    // https://code.google.com/p/webrtc/issues/detail?id=3417.

    RTCVideoTrack *localVideoTrack = nil;
#if !TARGET_IPHONE_SIMULATOR && TARGET_OS_IPHONE

    NSString *cameraID = nil;
    for (AVCaptureDevice *captureDevice in
         [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if (captureDevice.position == AVCaptureDevicePositionFront) {
            cameraID = [captureDevice localizedName];
            break;
        }
    }
    NSAssert(cameraID, @"Unable to get the front camera id");
    
    RTCVideoCapturer *capturer = [RTCVideoCapturer capturerWithDeviceName:cameraID];
    RTCMediaConstraints *mediaConstraints = [self defaultMediaStreamConstraints];
    RTCVideoSource *videoSource = [_factory videoSourceWithCapturer:capturer constraints:mediaConstraints];
    localVideoTrack = [_factory videoTrackWithID:@"ARDAMSv0" source:videoSource];
#endif
    return localVideoTrack;
}

- (RTCMediaStream *)createLocalMediaStream {
    RTCMediaStream* localStream = [_factory mediaStreamWithLabel:@"ARDAMS"];

    RTCVideoTrack *localVideoTrack = [self createLocalVideoTrack];
    if (localVideoTrack) {
        [localStream addVideoTrack:localVideoTrack];
        [_delegate appClient:self didReceiveLocalVideoTrack:localVideoTrack];
    }

    [localStream addAudioTrack:[_factory audioTrackWithID:@"ARDAMSa0"]];
    return localStream;
}

- (void)requestTURNServersWithURL:(NSURL *)requestURL
    completionHandler:(void (^)(NSArray *turnServers))completionHandler {
  NSParameterAssert([requestURL absoluteString].length);
  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:requestURL];
  // We need to set origin because TURN provider whitelists requests based on
  // origin.
  [request addValue:@"Mozilla/5.0" forHTTPHeaderField:@"user-agent"];
  [request addValue:self.serverHostUrl forHTTPHeaderField:@"origin"];
  [NSURLConnection sendAsyncRequest:request
                  completionHandler:^(NSURLResponse *response,
                                      NSData *data,
                                      NSError *error) {
    NSArray *turnServers = [NSArray array];
    if (error) {
      NSLog(@"Unable to get TURN server.");
      completionHandler(turnServers);
      return;
    }
    NSDictionary *dict = [NSDictionary dictionaryWithJSONData:data];
    turnServers = [RTCICEServer serversFromCEODJSONDictionary:dict];
    completionHandler(turnServers);
  }];
}

#pragma mark - Room server methods

- (void)registerWithRoomServerForRoomId:(NSString *)roomId
    completionHandler:(void (^)(ARDRegisterResponse *))completionHandler {
  NSString *urlString =
      [NSString stringWithFormat:kARDRoomServerRegisterFormat, self.serverHostUrl, roomId];
  NSURL *roomURL = [NSURL URLWithString:urlString];
  NSLog(@"Registering with room server.");
  __weak ARDAppClient *weakSelf = self;
  [NSURLConnection sendAsyncPostToURL:roomURL
                             withData:nil
                    completionHandler:^(BOOL succeeded, NSData *data) {
    ARDAppClient *strongSelf = weakSelf;
    if (!succeeded) {
      NSError *error = [self roomServerNetworkError];
      [strongSelf.delegate appClient:strongSelf didError:error];
      completionHandler(nil);
      return;
    }
    ARDRegisterResponse *response =
        [ARDRegisterResponse responseFromJSONData:data];
    completionHandler(response);
  }];
}

- (void)sendSignalingMessageToRoomServer:(ARDSignalingMessage *)message
    completionHandler:(void (^)(ARDMessageResponse *))completionHandler {
  NSData *data = [message JSONData];
  NSString *urlString =
      [NSString stringWithFormat:
          kARDRoomServerMessageFormat, self.serverHostUrl, _roomId, _clientId];
  NSURL *url = [NSURL URLWithString:urlString];
  NSLog(@"C->RS POST: %@", message);
  __weak ARDAppClient *weakSelf = self;
  [NSURLConnection sendAsyncPostToURL:url
                             withData:data
                    completionHandler:^(BOOL succeeded, NSData *data) {
    ARDAppClient *strongSelf = weakSelf;
    if (!succeeded) {
      NSError *error = [self roomServerNetworkError];
      [strongSelf.delegate appClient:strongSelf didError:error];
      return;
    }
    ARDMessageResponse *response =
        [ARDMessageResponse responseFromJSONData:data];
    NSError *error = nil;
    switch (response.result) {
      case kARDMessageResultTypeSuccess:
        break;
      case kARDMessageResultTypeUnknown:
        error =
            [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                       code:kARDAppClientErrorUnknown
                                   userInfo:@{
          NSLocalizedDescriptionKey: @"Unknown error.",
        }];
      case kARDMessageResultTypeInvalidClient:
        error =
            [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                       code:kARDAppClientErrorInvalidClient
                                   userInfo:@{
          NSLocalizedDescriptionKey: @"Invalid client.",
        }];
        break;
      case kARDMessageResultTypeInvalidRoom:
        error =
            [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                       code:kARDAppClientErrorInvalidRoom
                                   userInfo:@{
          NSLocalizedDescriptionKey: @"Invalid room.",
        }];
        break;
    };
    if (error) {
      [strongSelf.delegate appClient:strongSelf didError:error];
    }
    if (completionHandler) {
      completionHandler(response);
    }
  }];
}

- (void)unregisterWithRoomServer {
  NSString *urlString =
      [NSString stringWithFormat:kARDRoomServerByeFormat, self.serverHostUrl, _roomId, _clientId];
  NSURL *url = [NSURL URLWithString:urlString];
  NSLog(@"C->RS: BYE");
    //Make sure to do a POST
    [NSURLConnection sendAsyncPostToURL:url withData:nil completionHandler:^(BOOL succeeded, NSData *data) {
        if (succeeded) {
            NSLog(@"Unregistered from room server.");
        } else {
            NSLog(@"Failed to unregister from room server.");
        }
    }];
}

- (NSError *)roomServerNetworkError {
  NSError *error =
      [[NSError alloc] initWithDomain:kARDAppClientErrorDomain
                                 code:kARDAppClientErrorNetwork
                             userInfo:@{
    NSLocalizedDescriptionKey: @"Room server network error",
  }];
  return error;
}

#pragma mark - Collider methods

- (void)registerWithColliderIfReady {
  if (!self.isRegisteredWithRoomServer) {
    return;
  }
  // Open WebSocket connection.
  _channel =
      [[ARDWebSocketChannel alloc] initWithURL:_websocketURL
                                       restURL:_websocketRestURL
                                      delegate:self];
  [_channel registerForRoomId:_roomId clientId:_clientId];
}

- (void)sendSignalingMessageToCollider:(ARDSignalingMessage *)message {
  NSData *data = [message JSONData];
  [_channel sendData:data];
}

#pragma mark - Defaults

- (RTCMediaConstraints *)defaultMediaStreamConstraints {
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc]
          initWithMandatoryConstraints:nil
                   optionalConstraints:nil];
  return constraints;
}

- (RTCMediaConstraints *)defaultAnswerConstraints {
  return [self defaultOfferConstraints];
}

- (RTCMediaConstraints *)defaultOfferConstraints {
  NSArray *mandatoryConstraints = @[
      [[RTCPair alloc] initWithKey:@"OfferToReceiveAudio" value:@"true"],
      [[RTCPair alloc] initWithKey:@"OfferToReceiveVideo" value:@"false"]
  ];
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc]
          initWithMandatoryConstraints:mandatoryConstraints
                   optionalConstraints:nil];
  return constraints;
}

- (RTCMediaConstraints *)defaultPeerConnectionConstraints {
  NSArray *optionalConstraints = @[
      [[RTCPair alloc] initWithKey:@"internalSctpDataChannels" value:@"true"],
      [[RTCPair alloc] initWithKey:@"DtlsSrtpKeyAgreement" value:@"true"]
  ];
  RTCMediaConstraints* constraints =
      [[RTCMediaConstraints alloc]
          initWithMandatoryConstraints:nil
                   optionalConstraints:optionalConstraints];
  return constraints;
}

- (RTCICEServer *)defaultSTUNServer {
  NSURL *defaultSTUNServerURL = [NSURL URLWithString:kARDDefaultSTUNServerUrl];
  return [[RTCICEServer alloc] initWithURI:defaultSTUNServerURL
                                  username:@""
                                  password:@""];
}

@end
