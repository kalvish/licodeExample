//
//  LicodeSampleViewController.h
//  webRTCTest
//
//  Created by ganuka on 7/14/16.
//  Copyright © 2016 ganuka. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "RTCEAGLVideoView.h"
#import "ECRoom.h"

@interface LicodeSampleViewController : UIViewController <ECRoomDelegate>

@property (strong, nonatomic) IBOutlet UITextField *inputUsername;
@property (strong, nonatomic) IBOutlet UIButton *connectButton;
@property (strong, nonatomic) IBOutlet RTCEAGLVideoView *localView;
@property (strong, nonatomic) IBOutlet UILabel *statusLabel;

- (IBAction)connect:(id)sender;

@end
