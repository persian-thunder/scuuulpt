#pragma once

#include "ofxiOS.h"
#include <ARKit/ARKit.h>
#include "ofxARKit.h"

//Anchor STRUCT
struct AnchorWithFBO {
	ARAnchor *anchor; // Objective-C pointer
	std::shared_ptr<ofFbo> fbo; // shared_ptr so the FBO is allocated once and never copied
};

class ofApp : public ofxiOSApp {
    
public:
    
    ofApp (ARSession * session);
    ofApp();
    ~ofApp ();
    
    void setup();
    void update();
    void draw();
    void exit();
    
    void touchDown(ofTouchEventArgs &touch);
    void touchMoved(ofTouchEventArgs &touch);
    void touchUp(ofTouchEventArgs &touch);
    void touchDoubleTap(ofTouchEventArgs &touch);
    void touchCancelled(ofTouchEventArgs &touch);
    
    void lostFocus();
    void gotFocus();
    void gotMemoryWarning();
    void deviceOrientationChanged(int newOrientation);
	
	void removeOldestAnchor();
	void placeAnchor();        // captures the current cutout into an AR-anchored FBO
	float lastPlaceTime = 0;   // throttle drag-placement so we don't allocate FBOs too fast
	static const int MAX_TRAIL = 25;  // trail length (full-res FBOs ~12 MB each, keep small)
	int trailHead = 0;                // next ring slot to overwrite
	bool trailInited = false;         // FBO pool allocated yet?

    vector < matrix_float4x4 > mats;
    vector<ARAnchor*> anchors;
    ofCamera camera;
    ofTrueTypeFont font;
    ofImage img;

    // ====== AR STUFF ======== //
    ARSession * session;
    UIDevice * device;
    ARRef processor;

    ofShader meshShader;
	
	std::vector<AnchorWithFBO> anchorsWithFBOs;
	bool fboAllocated = false;
	ofFbo bodyFbo;
};


