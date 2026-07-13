#pragma once

#include "ofxiOS.h"
#include <ARKit/ARKit.h>
#include "ofxARKit.h"

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

	void placeCloudAnchor();   // builds a depth point-cloud snapshot ONCE and anchors it in the world
	void removeOldestCloud();
	bool  isTouching = false;  // true while a finger is down -> update() keeps placing (press & hold)
	float lastPlaceTime = 0;   // throttles continuous placement
	static constexpr float PLACE_INTERVAL = 0.1f; // seconds between placements while held (~10/sec)

	// Presets — cycled by triple-tap. NORMAL/GLITCH are per-voxel color bakes (at capture);
	// TRAIL is a per-frame render mode (feedback smear), not a color.
	enum ColorPreset { PRESET_NORMAL, PRESET_GLITCH, PRESET_TRAIL, PRESET_COUNT };
	int   colorPreset = PRESET_NORMAL;
	int   tapCount    = 0;     // triple-tap detector
	float lastTapTime = 0;

	// Feedback trail: GPU-only FBO feedback (no per-frame readback). Fade toward black, draw voxels,
	// present. Allocated WITHOUT depth (a depth attachment made the FBO render black on this setup).
	// TRAIL_FADE: 0.8 short … 0.97 long, ghostly.
	ofFbo   trailFbo;
	bool    trailAllocated = false;
	static constexpr float TRAIL_FADE = 0.9f;

	// Hard cap on stored cloud snapshots — evict the oldest beyond this to keep memory bounded.
	static constexpr int MAX_TRAIL_COUNT = 60;

    ofCamera camera;
    ofTrueTypeFont font;

    // ====== AR STUFF ======== //
    ARSession * session;
    UIDevice * device;
    ARRef processor;

	std::vector<AnchorWithCloud> anchorsWithClouds;
};
