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

	// Trail caps. placeAnchor() evicts oldest until BOTH are satisfied, so the trail can't OOM.
	//  - MAX_TRAIL_COUNT is the hard safety: a known-safe anchor count. The byte budget below
	//    under-estimates real GPU cost (driver rounding, ofTexture overhead, ARKit per-anchor
	//    state), so this count is the ceiling that actually keeps us alive. Raise cautiously.
	//  - TRAIL_BUDGET_MB is the secondary guard for when you bump resolution back up.
	static constexpr int   MAX_TRAIL_COUNT = 60;
	static constexpr float TRAIL_BUDGET_MB = 120.0f;

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


