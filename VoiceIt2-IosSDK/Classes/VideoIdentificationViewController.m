//
//  VideoIdentificationViewController.m
//  VoiceIt2-IosSDK
//
//  Created by VoiceIt Technologies, LLC
//  Copyright (c) 2020 VoiceIt Technologies, LLC. All rights reserved.
//

#import "VideoIdentificationViewController.h"
#import "Styles.h"

@interface VideoIdentificationViewController ()
@property(nonatomic, strong)  VoiceItAPITwo * myVoiceIt;
@property(nonatomic, strong)  NSString *videoPath;
@property CGFloat circleWidth;
@property CGFloat backgroundWidthHeight;
@property NSTimer * timer;
@property int currentChallenge;
@property BOOL isChallengeRetrieved;
@property NSString *lcoId;
@property NSNumber *livenessChallengeTime;
@property NSString *uiMessage;
@property NSString *livenessInstruction;
@property NSArray *lco;
@property NSString *audioPromptType;
@property NSArray *lcoStrings;
@end

@implementation VideoIdentificationViewController

#pragma mark - Life Cycle Methods

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        self.videoDataOutputQueue = dispatch_queue_create("VideoDataOutputQueue",
                                                          DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)viewDidLoad{
    [super viewDidLoad];
    self.myVoiceIt = (VoiceItAPITwo *) [self voiceItMaster];
    // Initialize Boolean and All
    self.lookingIntoCam = NO;
    self.continueRunning = YES;
    self.imageNotSaved = YES;
    self.identificationStarted = NO;
    self.lookingIntoCamCounter = 0;
    self.failCounter = 0;
    
    if(self.doLivenessDetection) {
        [self setLivenessData];
    } else{
        // Do any additional setup after loading the view.
        [self.progressView setHidden:YES];
        // Set up the AVCapture Session
        [self setupCaptureSession];
        [self setupVideoProcessing];
        [self setupScreen];
    }
}

- (void)viewWillAppear:(BOOL)animated{
    [super viewWillAppear:animated];
    [self.messageLabel setText: [ResponseManager getMessage:@"LOOK_INTO_CAM"]];
    [self.progressView startAnimation];
}

-(void)viewWillDisappear:(BOOL)animated{
    [super viewWillDisappear:animated];
    [self cleanupEverything];
}

#pragma mark - Setup Methods

-(void)setupScreen {
    [self.cancelButton setTitle:[ResponseManager getMessage:@"CANCEL"] forState:UIControlStateNormal];
    // Setup Awesome Transparent Background and radius for Verification Box
    if (!UIAccessibilityIsReduceTransparencyEnabled()) {
        self.view.backgroundColor = [UIColor clearColor];
        
        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        UIVisualEffectView *blurEffectView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        blurEffectView.frame = self.view.bounds;
        blurEffectView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        
        [self.view insertSubview:blurEffectView atIndex:0];
    } else {
        [[self view] setBackgroundColor:[UIColor colorWithRed:0.58 green:0.65 blue:0.65 alpha:0.6]];
    }
    [[self.identificationBox layer] setCornerRadius:10.0];
    [Utilities setBottomCornersForCancelButton:self.cancelButton];
    [self setupCameraCircle];
}

- (void)setupVideoProcessing {
    self.videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
    NSDictionary *rgbOutputSettings = @{
        (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
    };
    [self.videoDataOutput setVideoSettings:rgbOutputSettings];
    
    if (![self.captureSession canAddOutput:self.videoDataOutput]) {
        [self cleanupVideoProcessing];
        NSLog(@"Failed to setup video output");
        return;
    }
    [self.videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
    [self.videoDataOutput setSampleBufferDelegate:self queue:self.videoDataOutputQueue];
    [self.captureSession addOutput:self.videoDataOutput];
}

-(void)setupCaptureSession{
    // Setup Video Input Devices
    self.captureSession = [[AVCaptureSession alloc] init];
    [self.captureSession beginConfiguration];
    [self.captureSession setSessionPreset: AVCaptureSessionPresetMedium];
    self.videoDevice = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionFront];
    NSError * videoError;
    AVCaptureDeviceInput * videoInput = [AVCaptureDeviceInput deviceInputWithDevice: self.videoDevice error:&videoError];
    [self.captureSession addInput:videoInput];
    //Add Audio when doing liveness
    if(self.doLivenessDetection){
        AVCaptureDevice *audioCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        NSError *error = nil;
        AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioCaptureDevice error:&error];
        if (audioInput){
            [self.captureSession addInput:audioInput];
        }
        self.movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];
        Float64 TotalSeconds = 60;
        int32_t preferredTimeScale = 30;
        CMTime maxDuration = CMTimeMakeWithSeconds(TotalSeconds, preferredTimeScale);
        self.movieFileOutput.maxRecordedDuration = maxDuration;
        self.movieFileOutput.minFreeDiskSpaceLimit = 1024 * 1024;
        if ([self.captureSession canAddOutput:self.movieFileOutput]){
            [self.captureSession addOutput:self.movieFileOutput];
            [self.captureSession setSessionPreset:AVCaptureSessionPresetMedium];
        }
        AVCaptureConnection *CaptureConnection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
        if ([CaptureConnection isVideoOrientationSupported])
        {
            AVCaptureVideoOrientation orientation = AVCaptureVideoOrientationPortrait;
            [CaptureConnection setVideoOrientation:orientation];
        }
    }
}

-(void)setupCameraCircle{
    self.previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession: self.captureSession];
    [self.previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];
    
    // Setup code to capture face meta data
    AVCaptureMetadataOutput *metadataOutput = [[AVCaptureMetadataOutput alloc] init];
    // Have to add the output before setting metadata types
    [self.captureSession addOutput: metadataOutput];
    // We're only interested in faces
    [metadataOutput setMetadataObjectTypes:@[AVMetadataObjectTypeFace]];
    // This VC is the delegate. Please call us on the main queue
    [metadataOutput setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
    
    // Setup Little Camera Circle and Positions
    self.rootLayer = [[self identificationBox] layer];
    self.backgroundWidthHeight = (CGFloat) [self identificationBox].frame.size.height  * 0.50;
    CGFloat cameraViewWidthHeight = (CGFloat) [self identificationBox].frame.size.height  * 0.48;
    self.circleWidth = (self.backgroundWidthHeight - cameraViewWidthHeight) / 2;
    CGFloat backgroundViewX = ([self identificationBox].frame.size.width - self.backgroundWidthHeight)/2;
    CGFloat cameraViewX = ([self identificationBox].frame.size.width - cameraViewWidthHeight)/2;
    CGFloat backgroundViewY = VERIFICATION_BACKGROUND_VIEW_Y;
    CGFloat cameraViewY = backgroundViewY + self.circleWidth;
    
    self.cameraBorderLayer = [[CALayer alloc] init];
    self.progressCircle = [CAShapeLayer layer];
    
    [self.cameraBorderLayer setFrame:CGRectMake(backgroundViewX, backgroundViewY, self.backgroundWidthHeight, self.backgroundWidthHeight)];
    [self.previewLayer setFrame:CGRectMake(cameraViewX, cameraViewY, cameraViewWidthHeight, cameraViewWidthHeight)];
    [self.previewLayer setCornerRadius: cameraViewWidthHeight / 2];
    self.cameraCenterPoint = CGPointMake(self.cameraBorderLayer.frame.origin.x + (self.backgroundWidthHeight/2), self.cameraBorderLayer.frame.origin.y + (self.backgroundWidthHeight/2) );
    
    if ([self.videoDevice isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
        CGPoint autofocusPoint = self.cameraCenterPoint;
        [self.videoDevice setFocusPointOfInterest:autofocusPoint];
        [self.videoDevice setFocusMode:AVCaptureFocusModeLocked];
    }
    
    // Setup Progress Circle
    self.progressCircle .path = [UIBezierPath bezierPathWithArcCenter: self.cameraCenterPoint radius:(self.backgroundWidthHeight / 2) startAngle:-M_PI_2 endAngle:2 * M_PI - M_PI_2 clockwise:YES].CGPath;
    self.progressCircle.fillColor = [UIColor clearColor].CGColor;
    self.progressCircle.strokeColor = [UIColor clearColor].CGColor;
    self.progressCircle.lineWidth = self.circleWidth + 8.0;
    
    [self.cameraBorderLayer setBackgroundColor: [UIColor clearColor].CGColor];
    self.cameraBorderLayer.cornerRadius = self.backgroundWidthHeight / 2;
    
    // Setup Rectangle Around Face
    [Utilities setupFaceRectangle:self.faceRectangleLayer];
    
    [self.rootLayer addSublayer:self.cameraBorderLayer];
    [self.rootLayer addSublayer:self.progressCircle];
    [self.rootLayer addSublayer:self.previewLayer];
    [self.previewLayer addSublayer:self.faceRectangleLayer];
    [self.captureSession commitConfiguration];
    [self.captureSession startRunning];
}

#pragma mark - Player and liveness generation

- (IBAction)closeButtonClicked:(id)sender {
    [self dismissViewControllerAnimated:YES completion:^{
        [self userIdentificationCancelled]();
    }];
}

-(void) playSound:(NSString*) lco{
    if(self.doAudioPrompts){
        float time = [self.livenessChallengeTime floatValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, time * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self.player stop];
        });
        NSBundle * podBundle = [NSBundle bundleForClass: self.classForCoder];
        NSURL * bundleURL = [[podBundle resourceURL] URLByAppendingPathComponent:@"VoiceIt2-IosSDK.bundle"];
        NSString* soundFilePath = [self.contentLanguage isEqualToString:@"es-ES"] ?
        [NSString stringWithFormat:@"%@/%@",[[[NSBundle alloc] initWithURL:bundleURL] resourcePath], [self getSpanishPrompts:lco]] : [NSString stringWithFormat:@"%@/%@",[[[NSBundle alloc] initWithURL:bundleURL] resourcePath], lco];
        NSURL *soundFileURL = [NSURL fileURLWithPath:soundFilePath];
        NSError *error;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];
        self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:soundFileURL error:&error];
        self.player.numberOfLoops = 0; //Infinite
        [self.player play];
    }
}

-(NSString*) getSpanishPrompts: (NSString*)lco{
    if([lco isEqualToString:@"FACE_DOWN.wav"])
        return @"FACE_DOWN_ES.wav";
    if([lco isEqualToString:@"FACE_LEFT.wav"])
        return @"FACE_LEFT_ES.wav";
    if([lco isEqualToString:@"FACE_RIGHT.wav"])
        return @"FACE_RIGHT_ES.wav";
    if([lco isEqualToString:@"FACE_TILT_LEFT.wav"])
        return @"FACE_TILT_LEFT_ES.wav";
    if([lco isEqualToString:@"FACE_TILT_RIGHT.wav"])
        return @"FACE_TILT_RIGHT_ES.wav";
    if([lco isEqualToString:@"FACE_NEUTRAL.wav"])
        return @"FACE_NEUTRAL_ES.wav";
    if([lco isEqualToString:@"FACE_UP.wav"])
        return @"FACE_UP_ES.wav";
    if([lco isEqualToString:@"LIVENESS_FAILED.wav"])
        return @"LIVENESS_FAILED_ES.wav";
    if([lco isEqualToString:@"LIVENESS_SUCCESS.wav"])
        return @"LIVENESS_SUCCESS_ES.wav";
    if([lco isEqualToString:@"LIVENESS_TRY_AGAIN.wav"])
        return @"LIVENESS_TRY_AGAIN.wav";
    if([lco isEqualToString:@"SMILE.wav"])
        return @"SMILE_ES.wav";
    return @"";
}

-(void) illuminateCircles:(NSString*) lcoSignal{
    [self playSound: [NSString stringWithFormat:@"%@.wav",lcoSignal]];
    if ([lcoSignal isEqualToString:@"FACE_UP"]) {
        self.progressCircle.path = [UIBezierPath bezierPathWithArcCenter: self.cameraCenterPoint radius:(self.backgroundWidthHeight / 2) startAngle: 1.2 * M_PI endAngle: 1.8 * M_PI clockwise:YES].CGPath;
        self.progressCircle.drawsAsynchronously = YES;
        self.progressCircle.borderWidth = 20;
        self.progressCircle.fillColor =  [UIColor greenColor].CGColor;
    } else if ([lcoSignal isEqualToString:@"FACE_DOWN"]) {
        self.progressCircle.path = [UIBezierPath bezierPathWithArcCenter: self.cameraCenterPoint radius:(self.backgroundWidthHeight / 2) startAngle: 0.2 * M_PI endAngle: 0.8 * M_PI clockwise:YES].CGPath;
        self.progressCircle.drawsAsynchronously = YES;
        self.progressCircle.borderWidth = 20;
        self.progressCircle.fillColor =  [UIColor greenColor].CGColor;
    } else if ([lcoSignal isEqualToString:@"FACE_RIGHT"]) {
        self.progressCircle.path = [UIBezierPath bezierPathWithArcCenter: self.cameraCenterPoint radius:(self.backgroundWidthHeight / 2) startAngle: 1.75 * M_PI endAngle: 0.25 * M_PI clockwise:YES].CGPath;
        self.progressCircle.drawsAsynchronously = YES;
        self.progressCircle.borderWidth = 20;
        self.progressCircle.fillColor =  [UIColor greenColor].CGColor;
    } else if ([lcoSignal isEqualToString:@"FACE_LEFT"]) {
        self.progressCircle.path = [UIBezierPath bezierPathWithArcCenter: self.cameraCenterPoint radius:(self.backgroundWidthHeight / 2) startAngle: 0.75 * M_PI endAngle: 1.25 * M_PI clockwise:YES].CGPath;
        self.progressCircle.borderWidth = 20;
        self.progressCircle.drawsAsynchronously = YES;
        self.progressCircle.fillColor =  [UIColor greenColor].CGColor;
    } else if([lcoSignal isEqualToString:@"FACE_TILT_LEFT"]){
        self.progressCircle.path = [UIBezierPath bezierPathWithArcCenter: self.cameraCenterPoint radius:(self.backgroundWidthHeight / 2) startAngle: -0.5 * M_PI endAngle:-M_PI clockwise:NO].CGPath;
        self.progressCircle.borderWidth = 20;
        self.progressCircle.drawsAsynchronously = YES;
        self.progressCircle.fillColor =  [UIColor greenColor].CGColor;
    }else if([lcoSignal isEqualToString:@"FACE_TILT_RIGHT"]){
        self.progressCircle.path = [UIBezierPath bezierPathWithArcCenter: self.cameraCenterPoint radius:(self.backgroundWidthHeight / 2) startAngle: 0 endAngle: -0.4 * M_PI clockwise:NO].CGPath;
        self.progressCircle.borderWidth = 20;
        self.progressCircle.drawsAsynchronously = YES;
        self.progressCircle.fillColor =  [UIColor greenColor].CGColor;
    }
}

-(void)setLivenessChallengeMessages{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.cancelButton setTitle:[ResponseManager getMessage:@"Cancel"] forState:UIControlStateNormal];
    });
    [self recordVideoLiveness];
    [self setMessage:[self.lcoStrings firstObject]];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self illuminateCircles:[self.lco firstObject]];
    });
    
    float timeToStop = [self.livenessChallengeTime floatValue] + 5.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, timeToStop * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self stopRecordingVideoLiveness];
    });
    
    for(int i=1;i<self.lco.count;i++){
        float time = [self.livenessChallengeTime floatValue]/(self.lco.count);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, time * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self setMessage:self.lcoStrings[i]];
            [self illuminateCircles:self.lco[i]];
        });
    }
}

-(void)setLivenessData{
    [self.messageLabel setText: [ResponseManager getMessage:@"LOOK_INTO_CAM"]];
    [self.cancelButton setTitle:[ResponseManager getMessage:@"Cancel"] forState:UIControlStateNormal];
    [[self myVoiceIt] getLivenessID:self.userToVerifyUserId countryCode:
     self.contentLanguage callback:^(NSString *response) {
        NSDictionary *data = [Utilities getJSONObject:response];
        self.lcoStrings = [data valueForKey:@"lcoStrings"];
        self.isChallengeRetrieved = [data valueForKey:@"success"];
        self.lcoId = [data valueForKey:@"lcoId"];
        self.livenessChallengeTime = [data valueForKey:@"livenessChallengeTime"];
        self.lco = [data valueForKey:@"lco"];
        self.livenessInstruction = [data valueForKey:@"uiLivenessInstruction"];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setupCaptureSession];
            [self setupVideoProcessing];
            [self setupScreen];
            [self setupCameraCircle];
            [self.messageLabel setText: [ResponseManager getMessage:self.livenessInstruction]];
            [self.cancelButton setTitle:[ResponseManager getMessage:@"Continue"] forState:UIControlStateNormal];
        });
    } pageCateory:@"verification"];
}

- (void)recordVideoLiveness
{
    NSString *outputPath = [Utilities pathForTemporaryFileWithSuffix:@"mov"];
    NSURL *outputURL = [[NSURL alloc] initFileURLWithPath:outputPath];
    [self.movieFileOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];
}

-(void) stopRecordingVideoLiveness
{
    [self.movieFileOutput stopRecording];
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput
didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL
      fromConnections:(NSArray *)connections
                error:(NSError *)error
{
    //    [self.myVoiceIt videoVerificationWithLiveness:self.lcoId userId: self.userToVerifyUserId contentLanguage:self.contentLanguage videoPath:[outputFileURL path] phrase:self.thePhrase pageCategory:@"verification" callback:^(NSString * result) {
    //        [self handleLivenessResponse: result];
    //    }];
    
}

#pragma mark - Action Methods

-(void)startIdentificationProcess {
    [self startDelayedRecording:0.4];
}


-(void)startDelayedRecording:(NSTimeInterval)delayTime{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayTime * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if(self.continueRunning){
            [self setMessage:[ResponseManager getMessage:@"IDENTIFY" variable:self.thePhrase]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if(self.continueRunning){
                    [self startRecording];
                }
            });
        }
    });
}


- (UIImage *)imageFromCIImage:(CIImage *)ciImage {
    CIContext *ciContext = [CIContext contextWithOptions:nil];
    CGImageRef cgImage = [ciContext createCGImage:ciImage fromRect:[ciImage extent]];
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    return image;
}

-(void)saveImageData:(CIImage *)image{
    if ( image != nil){
        UIImage *uiimage = [self imageFromCIImage:image];
        self.finalCapturedPhotoData  = UIImageJPEGRepresentation(uiimage, 0.4);
        self.imageNotSaved = NO;
    }
}

-(void)showLoading{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.progressView setHidden:NO];
        [self setMessage:@""];
    });
}

-(void)removeLoading{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.progressView setHidden:YES];
    });
}


-(void)setAudioSessionInactive{
    [self.audioRecorder stop];
    NSError * err;
    [self.audioSession setActive:NO error:&err];
}

-(void)setMessage:(NSString *) newMessage {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.messageLabel setText: newMessage];
        [self.messageLabel setAdjustsFontSizeToFitWidth:YES];
    });
}

-(void)animateProgressCircle {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.progressCircle.strokeColor = [Styles getMainCGColor];
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
        animation.duration = 5;
        animation.removedOnCompletion = YES;
        animation.fromValue = @(0);
        animation.toValue = @(1);
        animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [self.progressCircle addAnimation:animation forKey:@"drawCircleAnimation"];
    });
}

-(void)startRecording {
    NSLog(@"Starting RECORDING");
    self.isRecording = YES;
    self.imageNotSaved = YES;
    self.cameraBorderLayer.backgroundColor = [UIColor clearColor].CGColor;
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSError *err;
    [audioSession setCategory:AVAudioSessionCategoryRecord error:&err];
    if (err) {
        NSLog(@"%@ %ld %@", [err domain], (long)[err code], [[err userInfo] description]);
    }
    err = nil;
    if (err) {
        NSLog(@"%@ %ld %@", [err domain], (long)[err code], [[err userInfo] description]);
    }
    
    self.audioPath = [Utilities pathForTemporaryFileWithSuffix:@"wav"];
    NSURL *url = [NSURL fileURLWithPath:self.audioPath];
    
    err = nil;
    self.audioRecorder = [[AVAudioRecorder alloc] initWithURL:url settings:[Utilities getRecordingSettings] error:&err];
    if(!self.audioRecorder){
        NSLog(@"recorder: %@ %ld %@", [err domain], (long)[err code], [[err userInfo] description]);
        return;
    }
    [self.audioRecorder setDelegate:self];
    [self.audioRecorder prepareToRecord];
    [self.audioRecorder setMeteringEnabled:YES];
    [self.audioRecorder recordForDuration:4.8];
    
    // Start Progress Circle Around Face Animation
    [self animateProgressCircle];
}

-(void)stopRecording{
    self.isRecording = NO;
    self.progressCircle.strokeColor = [UIColor clearColor].CGColor;
}

- (IBAction)cancelClicked:(id)sender {
    if(!self.doLivenessDetection){
        [self dismissViewControllerAnimated:YES completion:^{
            [self userIdentificationCancelled]();
        }];
    } else{
        if(self.identificationStarted == YES && [self.cancelButton.titleLabel.text isEqual:@"Continue"]){
            [self setLivenessChallengeMessages];
        }
        if(self.identificationStarted == NO || [self.cancelButton.titleLabel.text isEqual:@"Cancel"]){
            [self dismissViewControllerAnimated:YES completion:^{
                [self userIdentificationCancelled]();
                [self.player stop];
            }];
        }
        if([self.cancelButton.titleLabel.text isEqual:@"Done"]){
            [self dismissViewControllerAnimated:YES completion:^{
//                [self userIdentificationSuccessful](0,0,self.);
            }];
        }
    }
    
}

#pragma mark - Camera Delegate Methods

-(void)    captureOutput:(AVCaptureOutput *)output
didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects
          fromConnection:(AVCaptureConnection *)connection{
    BOOL faceFound = NO;
    for(AVMetadataObject *metadataObject in metadataObjects) {
        if([metadataObject.type isEqualToString:AVMetadataObjectTypeFace]) {
            faceFound = YES;
            AVMetadataObject * face = [self.previewLayer transformedMetadataObjectForMetadataObject:metadataObject];
            [Utilities showFaceRectangle:self.faceRectangleLayer face:face];
        }
    }
    
    if(faceFound) {
        self.lookingIntoCamCounter += 1;
        self.lookingIntoCam = self.lookingIntoCamCounter > MAX_TIME_TO_WAIT_TILL_FACE_FOUND;
        if (self.lookingIntoCam && !self.identificationStarted) {
            self.identificationStarted = YES;
            if(self.doLivenessDetection){
                
            } else {
                [self startIdentificationProcess];
            }
        }
    } else {
        self.lookingIntoCam = NO;
        self.lookingIntoCamCounter = 0;
        [self.faceRectangleLayer setHidden:YES];
    }
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    
    // Don't do any analysis when not looking into the camera
    if(!self.lookingIntoCam){
        return;
    }
    if(self.lookingIntoCamCounter > 5 && self.imageNotSaved){
        // Convert to CIPixelBuffer for faceDetector
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (pixelBuffer == NULL) { return; }
        
        // Create CIImage for faceDetector
        CIImage *image = [CIImage imageWithCVImageBuffer:pixelBuffer];
        [self saveImageData:image];
    }
}

#pragma mark - AVAudioRecorderDelegate Methods

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)flag{
    if(!self.continueRunning){
        return;
    }
    [self setAudioSessionInactive];
    [self stopRecording];
    [self showLoading];
    [self.myVoiceIt videoIdentification:self.groupToIdentifyGroupId contentLanguage: self.contentLanguage imageData:self.finalCapturedPhotoData audioPath:self.audioPath phrase:self.thePhrase callback:^(NSString * jsonResponse){
        [Utilities deleteFile:self.audioPath];
        self.imageNotSaved = YES;
        [self removeLoading];
        NSLog(@"Video Identification JSON Response : %@", jsonResponse);
        NSDictionary *jsonObj = [Utilities getJSONObject:jsonResponse];
        NSString * responseCode = [jsonObj objectForKey:@"responseCode"];
        
        if([responseCode isEqualToString:@"SUCC"]){
            [self setMessage:[ResponseManager getMessage:@"SUCCESS_IDENTIFIED"]];
            float faceConfidence = [[jsonObj objectForKey:@"faceConfidence"] floatValue];
            float voiceConfidence = [[jsonObj objectForKey:@"voiceConfidence"] floatValue];
            NSString * foundUserId = [jsonObj objectForKey:@"userId"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [self dismissViewControllerAnimated: YES completion:^{
                    [self userIdentificationSuccessful](faceConfidence, voiceConfidence, foundUserId, jsonResponse);
                }];
            });
        }
        
        else if([responseCode isEqualToString:@"FNFD"]){
            [self setMessage:[ResponseManager getMessage: responseCode]];
            [self startDelayedRecording:3.0];
            
        } else {
            self.failCounter += 1;
            
            if([Utilities isBadResponseCode:responseCode]){
                [self setMessage:[ResponseManager getMessage: @"CONTACT_DEVELOPER" variable: responseCode]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    [self dismissViewControllerAnimated: YES completion:^{
                        [self userIdentificationFailed](0.0, 0.0, jsonResponse);
                    }];
                });
            }
            else if(self.failCounter < self.failsAllowed){
                if([responseCode isEqualToString:@"STTF"] || [responseCode isEqualToString:@"PDNM"]){
                    [self setMessage:[ResponseManager getMessage: responseCode variable:self.thePhrase]];
                    [self startDelayedRecording:3.0];
                }
                else if ([responseCode isEqualToString:@"PNTE"]){
                    [self setMessage:[ResponseManager getMessage: @"PNTE_IDENTIFICATION"]];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        [self dismissViewControllerAnimated: YES completion:^{
                            [self userIdentificationFailed](0.0, 0.0, jsonResponse);
                        }];
                    });
                }else{
                    [self setMessage:[ResponseManager getMessage: responseCode]];
                    [self startDelayedRecording:3.0];
                }
            } else {
                [self setMessage:[ResponseManager getMessage: @"TOO_MANY_ATTEMPTS"]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    float faceConfidence = [responseCode isEqualToString:@"FAIL"] ? [[jsonObj objectForKey:@"faceConfidence"] floatValue] : 0.0;
                    float voiceConfidence = [responseCode isEqualToString:@"FAIL"] ? [[jsonObj objectForKey:@"voiceConfidence"] floatValue] : 0.0;
                    [self dismissViewControllerAnimated: YES completion:^{
                        [self userIdentificationFailed](faceConfidence, voiceConfidence, jsonResponse);
                    }];
                });
            }
        }
    }];
}

-(void)audioRecorderEncodeErrorDidOccur:(AVAudioRecorder *)recorder error:(NSError *)error
{
    NSLog(@"fail because %@", error.localizedDescription);
}

#pragma mark - Cleanup Methods

- (void)cleanupCaptureSession {
    [self.captureSession stopRunning];
    [self cleanupVideoProcessing];
    self.captureSession = nil;
    [self.previewLayer removeFromSuperlayer];
}

- (void)cleanupVideoProcessing {
    if (self.videoDataOutput) {
        [self.captureSession removeOutput:self.videoDataOutput];
    }
    self.videoDataOutput = nil;
}

-(void)cleanupEverything {
    [self setAudioSessionInactive];
    [self cleanupCaptureSession];
    self.continueRunning = NO;
    
}

@end
