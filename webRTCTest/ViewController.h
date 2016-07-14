//
//  ViewController.h
//  webRTCTest
//
//  Created by ganuka on 5/10/16.
//  Copyright © 2016 ganuka. All rights reserved.
//

#import <UIKit/UIKit.h>

#import <libjingle_peerconnection/RTCEAGLVideoView.h>
#import <AppRTC/ARDAppClient.h>

@interface ViewController : UIViewController <ARDAppClientDelegate, RTCEAGLVideoViewDelegate>

@property (strong, nonatomic) ARDAppClient *client;
@property (strong, nonatomic) IBOutlet RTCEAGLVideoView *remoteView;
@property (strong, nonatomic) IBOutlet RTCEAGLVideoView *localView;
@property (strong, nonatomic) RTCVideoTrack *localVideoTrack;
@property (strong, nonatomic) RTCVideoTrack *remoteVideoTrack;
@property (weak, nonatomic) IBOutlet UITextField *roomText;
@property (weak, nonatomic) IBOutlet UIImageView *imageReceived;


- (IBAction)onclickstart:(id)sender;

- (IBAction)onSendMessageToPeer:(id)sender;
@end

