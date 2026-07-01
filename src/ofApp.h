#pragma once

#include "ofxiOS.h"
#include <ARKit/ARKit.h>
#include "ofxARKit.h"

//Anchor STRUCT
struct AnchorWithFBO {
	ARAnchor *anchor; // Objective-C pointer
	std::shared_ptr<ofFbo> fbo; // shared_ptr so the FBO is allocated once and never copied
};

// A point cloud snapshot, built ONCE on tap from the depth frame, then drawn as static geometry.
struct AnchorWithCloud {
	ARAnchor *anchor;
	std::shared_ptr<ofVboMesh> cloud;  // colored FILL quads (smaller, drawn on top)
	std::shared_ptr<ofVboMesh> border; // BLACK quads (full size, behind) -> black border per cell
	float baseHue;                     // 0..1 hue captured at placement; animated over time in draw()
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
	void placeCloudAnchor();   // builds a depth point cloud ONCE and anchors it as static geometry
	void removeOldestCloud();
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
	std::vector<AnchorWithCloud> anchorsWithClouds;
	bool fboAllocated = false;
	ofFbo bodyFbo;
	ofFloatImage depthPreview;  // Step B: reused grayscale view of ARKit person depth
	ofVboMesh livePointCloud;   // Stage 2: live 3D point cloud unprojected from depth
	ofShader  pointShader;      // (unused) old gl_PointSize experiment
	ofShader  cloudShader;      // live: soft additive glow + animated hue for the point clouds
};


