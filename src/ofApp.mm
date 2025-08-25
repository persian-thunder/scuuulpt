#include "ofApp.h"

using namespace ofxARKit::common;
using namespace ofxARKit::core;

//--------------------------------------------------------------
ofApp :: ofApp (ARSession * session){
    this->session = session;
    cout << "creating ofApp with provided session" << endl;
    
}


ofApp::ofApp(){
    cout << "creating ofApp with new session" << endl;
    
    // Initialize AR session directly
    SessionFormat format;
    format.enableLighting();
    this->session = generateNewSession(format);
}

//--------------------------------------------------------------
ofApp :: ~ofApp () {
    cout << "destroying ofApp" << endl;
}

//--------------------------------------------------------------
void ofApp::setup() {
	ofClear(0,0,0,0);
	
    img.load("OpenFrameworks.png");
    
    int fontSize = 8;
    if (ofxiOSGetOFWindow()->isRetinaSupportedOnDevice())
        fontSize *= 2;
    
    font.load("fonts/mono0755.ttf", fontSize);
    
    processor = ARProcessor::create(session);
    processor->setup();

    
}



//--------------------------------------------------------------
void ofApp::update(){
	//allocate FBO
	if (!fboAllocated) {
		bodyFbo.allocate(ofGetWidth(), ofGetHeight());
		fboAllocated = true;
	}
	
	
    processor->update();
    
                
#if defined(__IPHONE_13_0)

    // check Camera.h for shader using those :
//     CVOpenGLESTextureRef _tex = processor->getCameraTexture();`
//     CVOpenGLESTextureRef matteAlpha = processor->getTextureMatteAlpha();
//     CVOpenGLESTextureRef matteDepth = processor->getTextureMatteDepth();
//     CVOpenGLESTextureRef depth = processor->getTextureDepth();
//     ofMatrix3x3 affineCoeff = processor->getAffineTransform();
    
#endif
    
    
}

//--------------------------------------------------------------
void ofApp::draw() {
	ofClear(0,0,0, 0);
	ofBackground(255, 255, 255);
	//processor->setARCameraMatrices();
    ofEnableAlphaBlending();
    
    //ofDisableDepthTest();

    processor->drawCameraDebugPersonSegmentation();
    //ofEnableDepthTest();
    
    if (session.currentFrame){
        if (session.currentFrame.camera){
            camera.begin();
            processor->setARCameraMatrices();
            
			//here we iterate through all of our anchors that we placed in touchDown
			for (auto& anchorWithFbo: anchorsWithFBOs) {
				ofPushMatrix();
				ofMatrix4x4 mat = convert<matrix_float4x4, ofMatrix4x4>(anchorWithFbo.anchor.transform);
				ofMultMatrix(mat);
				ofRotate(-90,0,0,1); //added
				ofSetColor(255); //added
				ofScale(-1,1,1);

				ofDisableDepthTest();
				anchorWithFbo.fbo.draw(-0.25 / 2, -0.25, 0.25, 0.5);
				ofEnableDepthTest();
				ofPopMatrix();
			}
			
			/*
            for (int i = 0; i < session.currentFrame.anchors.count; i++){
                ARAnchor * anchor = session.currentFrame.anchors[i];
                
                // note - if you need to differentiate between different types of anchors, there is a 
                // "isKindOfClass" method in objective-c that could be used. For example, if you wanted to 
                // check for a Plane anchor, you could put this in an if statement.
                // if([anchor isKindOfClass:[ARPlaneAnchor class]]) { // do something if we find a plane anchor}
                // Not important for this example but something good to remember.
                
                ofPushMatrix();
                ofMatrix4x4 mat = convert<matrix_float4x4, ofMatrix4x4>(anchor.transform);
                ofMultMatrix(mat);
                
                ofSetColor(255);
                ofRotate(90,0,0,1);
                
                img.draw(-0.25 / 2, -0.25 / 2,0.25,0.25);
                
                
                ofPopMatrix();
            }*/
          
            camera.end();
        }
        
    }
	ofDisableAlphaBlending();
	ofEnableDepthTest();
    ofDisableDepthTest();
    // ========== DEBUG STUFF ============= //
    //processor->debugInfo.drawDebugInformation(font);
   
    
}

//--------------------------------------------------------------
void ofApp::exit() {
    //
}



//--------------------------------------------------------------
void ofApp::touchDown(ofTouchEventArgs &touch){
	
    
    if (session.currentFrame){
		
		if (anchorsWithFBOs.size() > 40) {
			removeOldestAnchor();
		}
		
        ARFrame *currentFrame = [session currentFrame];

        matrix_float4x4 translation = matrix_identity_float4x4;
        translation.columns[3].z = -0.3; //WAS ORIGINALLY -.2
        matrix_float4x4 transform = matrix_multiply(currentFrame.camera.transform, translation);

        // Add a new anchor to the session
        ARAnchor *anchor = [[ARAnchor alloc] initWithTransform:transform];
        [session addAnchor:anchor];
		
		ofFbo newFbo;
		newFbo.allocate(ofGetWidth(), ofGetHeight(), GL_RGBA);
		
		newFbo.begin();
		ofClear(0,0,0,0);
		ofEnableAlphaBlending();
		processor->drawCameraDebugPersonSegmentation();
		ofDisableAlphaBlending();
		newFbo.end();
		
		AnchorWithFBO anchorWithFbo = { anchor, newFbo };
		anchorsWithFBOs.push_back(anchorWithFbo);
		
    }
}

void ofApp::removeOldestAnchor(){
	if (!anchorsWithFBOs.empty()){
		ARAnchor* anchor = anchorsWithFBOs.front().anchor;
		[session removeAnchor:anchor];

		// Delete anchor and FBO from vector
		anchorsWithFBOs.erase(anchorsWithFBOs.begin());
	}
}

//--------------------------------------------------------------
void ofApp::touchMoved(ofTouchEventArgs &touch){
    
}

//--------------------------------------------------------------
void ofApp::touchUp(ofTouchEventArgs &touch){
    
}

//--------------------------------------------------------------
void ofApp::touchDoubleTap(ofTouchEventArgs &touch){
    
}

//--------------------------------------------------------------
void ofApp::lostFocus(){
    
}

//--------------------------------------------------------------
void ofApp::gotFocus(){
    
}

//--------------------------------------------------------------
void ofApp::gotMemoryWarning(){
    
}

//--------------------------------------------------------------
void ofApp::deviceOrientationChanged(int newOrientation){
  
    processor->deviceOrientationChanged(newOrientation);
}


//--------------------------------------------------------------
void ofApp::touchCancelled(ofTouchEventArgs& args){
    
}


