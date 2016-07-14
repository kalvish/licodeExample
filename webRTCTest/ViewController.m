//
//  ViewController.m
//  webRTCTest
//
//  Created by ganuka on 5/10/16.
//  Copyright © 2016 ganuka. All rights reserved.
//

#import "ViewController.h"
#import <QuartzCore/QuartzCore.h>

@interface ViewController ()

@property NSMutableData *rxData;

@end

@implementation ViewController

@synthesize rxData;
int rxDataCount = 0;
int intMediaLength = 0;

@synthesize imageReceived;

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.

    /* RTCEAGLVideoViewDelegate provides notifications on video frame dimensions */
    [self.remoteView setDelegate:self];
    [self.localView setDelegate:self];
    
   }

- (void) viewWillDisappear:(BOOL)animated {
    [self disconnect];
}

- (void)applicationWillResignActive:(UIApplication*)application {
    [self disconnect];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)appClient:(ARDAppClient *)client didChangeState:(ARDAppClientState)state {
    switch (state) {
        case kARDAppClientStateConnected:
            NSLog(@"Client connected.");
            break;
        case kARDAppClientStateConnecting:
            NSLog(@"Client connecting.");
            break;
        case kARDAppClientStateDisconnected:
            NSLog(@"Client disconnected.");
            [self remoteDisconnected];
            break;
    }
}

- (void)appClient:(ARDAppClient *)client didReceiveLocalVideoTrack:(RTCVideoTrack *)localVideoTrack {
    if (self.localVideoTrack) {
        [self.localVideoTrack removeRenderer:self.localView];
        self.localVideoTrack = nil;
        [self.localView renderFrame:nil];
    }
    self.localVideoTrack = localVideoTrack;
    [self.localVideoTrack addRenderer:self.localView];

}

- (void)appClient:(ARDAppClient *)client didReceiveRemoteVideoTrack:(RTCVideoTrack *)remoteVideoTrack {
    self.remoteVideoTrack = remoteVideoTrack;
    [self.remoteVideoTrack addRenderer:self.remoteView];
}

- (void)appClient:(ARDAppClient *)client rtcDataChannel:(RTCDataChannel *)rtcDC didReceiveRCTDataBufer:(RTCDataBuffer *)rtcDataBuffer {
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSData *temp = rtcDataBuffer.data;
        
        NSString* str = [[NSString alloc] initWithData:temp
                                              encoding:NSUTF8StringEncoding];
    
        if (str && [str length] > 0){
            NSLog(@"Contains string");
            
            NSError *error;
            id jsonResult = [NSJSONSerialization JSONObjectWithData:temp options:0 error:&error];
            if (jsonResult && ([jsonResult isKindOfClass:[NSDictionary class]]))
            {
                NSDictionary *dict = (NSDictionary*)jsonResult;
                NSString *messageText = [dict objectForKey:@"message"];
                
                if (messageText)
                {
                    intMediaLength = [messageText intValue];
                    rxData = nil;
                    rxDataCount = 0;
                    //NSLog(@"Direct Message received: [%@], int value is %d", messageText, intMediaLength);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        //[self.delegate onMessage:messageText sender:self];
                    });
                }
            }
        }else{
            NSLog(@"Does't contains string");
            
            if(rxData==nil){
                rxData = [[NSMutableData alloc] init];
            }
            
            [rxData appendData:temp];
            rxDataCount+=temp.length;
            
            if(rxDataCount==intMediaLength){
                UIImage *imageRx= [UIImage imageWithData:rxData];
                [imageReceived setImage:imageRx];
            }
        }

        
    });
  
    //imageReceived.image = imageRx;
    
//    id message = nil;
//    NSError *error;
//    
//    NSData *temp = rtcDataBuffer.data;
//    NSString* str = [[NSString alloc] initWithData:temp
//                                          encoding:NSUTF8StringEncoding];
//    
//    
//    if (str && [str length] > 0){
//        NSLog(@"Contains string");
//    }else{
//        NSLog(@"Does't contains string");
//        
//    }
//    
//    id jsonResult = [NSJSONSerialization JSONObjectWithData:rtcDataBuffer.data options:0 error:&error];
//    if (error)
//    {
//        // Could not parse JSON data, so just pass it as it is
//        message = rtcDataBuffer.data;
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

- (void)appClient:(ARDAppClient *)client didError:(NSError *)error {
    /* Handle the error */
    UIAlertView* alertView = [[UIAlertView alloc] initWithTitle:nil
                                                        message:[NSString stringWithFormat:@"%@", error]
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil];
    [alertView show];
    [self disconnect];
}


- (void)videoView:(RTCEAGLVideoView *)videoView didChangeVideoSize:(CGSize)size {
    /* resize self.localView or self.remoteView based on the size returned */
}

- (IBAction)onclickstart:(id)sender {
    NSString * temp = self.roomText.text;
    
    //Connect to the room
    [self disconnect];
    /* Initializes the ARDAppClient with the delegate assignment */
    self.client = [[ARDAppClient alloc] initWithDelegate:self];
    [self.client setServerHostUrl:@"https://apprtc.appspot.com"];
    [self.client connectToRoomWithId:temp options:nil];

    /*UIImage * thumbnail = [UIImage imageNamed: @"test.PNG"];
    NSData *imagedata = UIImagePNGRepresentation(thumbnail);
    UIImage *imageRx= [UIImage imageWithData:imagedata];
    [imageReceived setImage:imageRx];*/
}

-(void)onSendMessageToPeer:(id)sender {
    
    // start the loop
    [self incrementCounter:[NSNumber numberWithInt:0]];
    
}

-(void) incrementCounter:(NSNumber *)i {
    if(self.client){
        if ([[UIScreen mainScreen] respondsToSelector:@selector(scale)])
            UIGraphicsBeginImageContextWithOptions(self.view.window.bounds.size, NO, [UIScreen mainScreen].scale);
        else
            UIGraphicsBeginImageContext(self.view.window.bounds.size);
        
        [self.view.window.layer renderInContext:UIGraphicsGetCurrentContext()];
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        //[imageReceived setImage:image];
        [self.client sendMessage:image];
        
        
    }
   // [myLabel setText:[NSString stringWithFormat:@"%d", [i intValue]]]; // show the result!
    [self performSelector:@selector(incrementCounter:) withObject:[NSNumber numberWithInt:i.intValue+1] afterDelay:0.2];
}

- (void)disconnect {
    if (self.client) {
        if (self.localVideoTrack) [self.localVideoTrack removeRenderer:self.localView];
        if (self.remoteVideoTrack) [self.remoteVideoTrack removeRenderer:self.remoteView];
        self.localVideoTrack = nil;
        [self.localView renderFrame:nil];
        self.remoteVideoTrack = nil;
        [self.remoteView renderFrame:nil];
        [self.client disconnect];
    }
}

- (void)remoteDisconnected {
    if (self.remoteVideoTrack) [self.remoteVideoTrack removeRenderer:self.remoteView];
    self.remoteVideoTrack = nil;
    [self.remoteView renderFrame:nil];
    //[self videoView:self.localView didChangeVideoSize:self.localVideoSize];
    
}

@end
