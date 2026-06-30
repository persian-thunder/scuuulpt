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
				if(!anchorWithFbo.anchor || !anchorWithFbo.fbo) continue; // empty ring slot
				ofPushMatrix();
				ofMatrix4x4 mat = convert<matrix_float4x4, ofMatrix4x4>(anchorWithFbo.anchor.transform);
				ofMultMatrix(mat);
				ofRotate(-90,0,0,1); //added
				ofSetColor(255); //added
				ofScale(-1,1,1);

				ofDisableDepthTest();
				if(anchorWithFbo.fbo) anchorWithFbo.fbo->draw(-0.25 / 2, -0.25, 0.25, 0.5);
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
    // Place ONE cutout per tap. This runs in the touch event (between frames), which is the
    // only safe time to snapshot an FBO — doing it inside update()/draw() collides with the
    // in-flight Metal camera command buffer and crashes.
    placeAnchor();
    lastPlaceTime = ofGetElapsedTimef();
}

void ofApp::placeAnchor(){
    if (session.currentFrame){

        // Half-res RGBA8 snapshot (~3 MB each). RGBA4444 was tried but this build runs the GLES2
        // renderer, where GL_RGBA4 is not a valid texture internalformat — so we stay at GL_RGBA.
        // (oF FBOs already allocate with no depth/stencil/MSAA by default, so the color texture
        // below is the entire per-snapshot cost.)
        float fboScale = .35;   // lowered from .5: ~2x less memory/snapshot, trail draws small anyway
        int fboW = ofGetWidth()  * fboScale;
        int fboH = ofGetHeight() * fboScale;

        // Budget-driven cap: derive the max trail length from the real per-FBO cost and the memory
        // budget, then evict oldest until the NEW snapshot will fit. This bounds total trail memory
        // to ~TRAIL_BUDGET_MB no matter the resolution or draw speed, so it can't OOM the app.
        float fboMB    = (fboW * (float)fboH * 4.0f) / (1024.0f * 1024.0f); // RGBA8 = 4 bytes/px
        int   budgetN  = std::max(1, (int)(TRAIL_BUDGET_MB / fboMB));
        int   maxTrail = std::min(budgetN, MAX_TRAIL_COUNT);               // hard count wins
        while (anchorsWithFBOs.size() >= (size_t)maxTrail) {
            removeOldestAnchor();
        }

        ARFrame *currentFrame = [session currentFrame];

        matrix_float4x4 translation = matrix_identity_float4x4;
        translation.columns[3].z = -0.3;
        matrix_float4x4 transform = matrix_multiply(currentFrame.camera.transform, translation);

        ARAnchor *anchor = [[ARAnchor alloc] initWithTransform:transform];
        [session addAnchor:anchor];

        auto newFbo = std::make_shared<ofFbo>();
        newFbo->allocate(fboW, fboH, GL_RGBA);

        newFbo->begin();
        ofClear(0,0,0,0);
        ofEnableAlphaBlending();
        processor->drawCameraDebugPersonSegmentation();
        ofDisableAlphaBlending();
        newFbo->end();

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
void ofApp::gotMemoryWarning(){
	// iOS is about to start killing apps. Drop the whole trail NOW (frees every snapshot's GPU
	// texture via shared_ptr) so we survive instead of getting jetsam'd. The budget cap should
	// normally keep us clear of this; this is the last-resort backstop for baseline growth.
	ofLogWarning("ofApp") << "memory warning -> dumping " << anchorsWithFBOs.size() << " trail FBOs";
	while (!anchorsWithFBOs.empty()) {
		removeOldestAnchor();
	}
}

//--------------------------------------------------------------
void ofApp::touchMoved(ofTouchEventArgs &touch){
    // Hold + drag to place continuously, but THROTTLED. touchMoved fires dozens of times a
    // second; placing on every one allocates FBOs faster than the GPU frees them and blows past
    // 1 GB. Cap it to ~10 placements/sec — still a smooth continuous trail, bounded memory.
    float now = ofGetElapsedTimef();
    if(now - lastPlaceTime > 0.025f){
        lastPlaceTime = now;
        placeAnchor();
    }
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
void ofApp::deviceOrientationChanged(int newOrientation){

    processor->deviceOrientationChanged(newOrientation);
}


//--------------------------------------------------------------
void ofApp::touchCancelled(ofTouchEventArgs& args){
}


