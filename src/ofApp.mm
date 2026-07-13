#include "ofApp.h"
#include <cstddef>

using namespace ofxARKit::common;
using namespace ofxARKit::core;

//--------------------------------------------------------------
ofApp :: ofApp (ARSession * session){
    this->session = session;
    cout << "creating ofApp with provided session" << endl;

}

//--------------------------------------------------------------
ofApp::ofApp(){
    cout << "creating ofApp with new session" << endl;

    // init AR session
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

    // Render at 30fps for a calmer, more filmic cadence (camera still captures 60; we display 30).
    // Also gives GPU headroom -> steadier frame pacing = smoother.
    ofSetFrameRate(60);

    int fontSize = 8;
    if (ofxiOSGetOFWindow()->isRetinaSupportedOnDevice())
        fontSize *= 2;
    font.load("fonts/mono0755.ttf", fontSize);

	//ARProcessor API
    processor = ARProcessor::create(session);
    processor->setup();

    // portrait orientation overload
    processor->deviceOrientationChanged(UIInterfaceOrientationPortrait);
}



//--------------------------------------------------------------
void ofApp::update(){
    processor->update();

	// press & hold to draw anchor, intervals
    if (isTouching) {
        float now = ofGetElapsedTimef();
        if (now - lastPlaceTime > PLACE_INTERVAL) {
            lastPlaceTime = now;
            placeCloudAnchor();
        }
    }
}

//--------------------------------------------------------------
void ofApp::draw() {
    // PROTOTYPE: trail-only view. Camera background and the NORMAL/GLITCH paths are disabled —
    // just the voxel feedback trail on black, so we can dial the trail in isolation.
    ofClear(0, 0, 0, 255);   // black background

    // Draw the voxel clouds with the AR camera matrices. Painter's order (no depth test) so the FBO
    // stays complete without a depth attachment.
    auto drawVoxels = [&]() {
        if (!session.currentFrame || !session.currentFrame.camera) return;
        camera.begin();
        processor->setARCameraMatrices();
        ofEnableBlendMode(OF_BLENDMODE_ALPHA);
        ofDisableDepthTest();
        for (auto& ac : anchorsWithClouds) {
            if (!ac.anchor || !ac.cloud) continue;
            ofPushMatrix();
            ofMatrix4x4 mat = convert<matrix_float4x4, ofMatrix4x4>(ac.anchor.transform);
            ofMultMatrix(mat);
            ofSetColor(0);   if (ac.border) ac.border->draw();  // black border cells
            ofSetColor(255); ac.cloud->draw();                  // real per-voxel camera colors
            ofPopMatrix();
        }
        ofSetColor(255);
        camera.end();
    };

    // GPU-only feedback: dim the FBO toward black, draw fresh voxels, present. No readback = fast.
    if (!trailAllocated) {
        trailFbo.allocate(ofGetWidth(), ofGetHeight(), GL_RGBA);   // NO depth (kept it from failing)
        trailFbo.begin(); ofClear(0,0,0,255); trailFbo.end();
        trailAllocated = true;
    }
    trailFbo.begin();
        ofEnableAlphaBlending();
        ofSetColor(0, 0, 0, 255 * (1.0f - TRAIL_FADE));   // dim old content each frame
        ofDrawRectangle(0, 0, ofGetWidth(), ofGetHeight());
        drawVoxels();
    trailFbo.end();

    ofDisableAlphaBlending();
    ofSetColor(255);
    trailFbo.draw(0, 0, ofGetWidth(), ofGetHeight());
}

//--------------------------------------------------------------
void ofApp::exit() {
}

//--------------------------------------------------------------
void ofApp::touchDown(ofTouchEventArgs &touch){
    float now = ofGetElapsedTimef();

    // triple-tap cycles the color preset (NORMAL <-> GLITCH). Taps within 0.35s count together.
    tapCount = (now - lastTapTime < 0.35f) ? tapCount + 1 : 1;
    lastTapTime = now;
    if (tapCount >= 3) {
        colorPreset = (colorPreset + 1) % PRESET_COUNT;
        tapCount = 0;
        const char *names[] = { "NORMAL", "GLITCH", "TRAIL" };
        ofLogNotice("preset") << "preset -> " << names[colorPreset];
    }

    // place then update() keeps placing while held (press & hold)
    isTouching = true;
    placeCloudAnchor();
    lastPlaceTime = now;
}

void ofApp::removeOldestCloud(){
	if (!anchorsWithClouds.empty()){
		[session removeAnchor:anchorsWithClouds.front().anchor];
		anchorsWithClouds.erase(anchorsWithClouds.begin()); // shared_ptr frees the VBO
	}
}

//--------------------------------------------------------------
void ofApp::placeCloudAnchor(){
    if (!session.currentFrame || !session.currentFrame.estimatedDepthData) return;

    while (anchorsWithClouds.size() >= (size_t)MAX_TRAIL_COUNT) removeOldestCloud();

    // grab ARframe objects
    ARFrame *frame = session.currentFrame;
    matrix_float4x4 camXform = frame.camera.transform;   // value copy of the pose
    CVPixelBufferRef depthMap = frame.estimatedDepthData; //depth image


    CVPixelBufferLockBaseAddress(depthMap, kCVPixelBufferLock_ReadOnly); //have to lock or else corrupt data
    size_t w = CVPixelBufferGetWidth(depthMap);
    size_t h = CVPixelBufferGetHeight(depthMap);
    size_t rowFloats = CVPixelBufferGetBytesPerRow(depthMap) / sizeof(float);
    float *base = (float *)CVPixelBufferGetBaseAddress(depthMap);

    std::vector<float> depth;                             // our own copy of the depth grid
    if (base) depth.assign(base, base + h * rowFloats);
    CVPixelBufferUnlockBaseAddress(depthMap, kCVPixelBufferLock_ReadOnly);

    // Copy the camera image (biplanar YCbCr) too, so each voxel can wear the REAL color it captured.
    CVPixelBufferRef camBuf = frame.capturedImage;
    std::vector<uint8_t> yCopy, cCopy;
    size_t camW = 0, camH = 0, yStride = 0, cStride = 0;
    if (camBuf) {
        CVPixelBufferLockBaseAddress(camBuf, kCVPixelBufferLock_ReadOnly);
        camW    = CVPixelBufferGetWidthOfPlane(camBuf, 0);
        camH    = CVPixelBufferGetHeightOfPlane(camBuf, 0);
        yStride = CVPixelBufferGetBytesPerRowOfPlane(camBuf, 0);
        cStride = CVPixelBufferGetBytesPerRowOfPlane(camBuf, 1);
        uint8_t *yP = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(camBuf, 0);
        uint8_t *cP = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(camBuf, 1);
        if (yP && cP) {
            yCopy.assign(yP, yP + camH * yStride);
            cCopy.assign(cP, cP + (camH/2) * cStride);
        }
        CVPixelBufferUnlockBaseAddress(camBuf, kCVPixelBufferLock_ReadOnly);
    }
    frame = nil;                                          // stop referencing ARKit's frame now

    if (depth.empty()) return;
    bool haveColor = !yCopy.empty() && !cCopy.empty();

    // ---- Build the cloud from the LOCAL copy (no ARKit buffers held). Each point is a small
    // camera-facing QUAD (2 tris), drawn with oF's DEFAULT shader (the custom point shader / GL_POINTS
    // renders nothing on this ES2 device). s = half-quad size in meters.
    auto cloud  = std::make_shared<ofVboMesh>();  // colored fill
    auto border = std::make_shared<ofVboMesh>();  // black border
    cloud->setMode(OF_PRIMITIVE_TRIANGLES);
    border->setMode(OF_PRIMITIVE_TRIANGLES);
    const int   step = 1;            // ~256x192 -> ~5k points (used for the mean-depth pass)
    const float UP   = 1.41f;        // depth upsample factor per axis: 1.41 (sqrt2) ~= 2x total points; 2.0 = 4x
    const float tanHalfFovY = 0.7f;  // rough pinhole; tune if scale looks off
    const float aspect = (float)w / (float)h;
    const float RANGE = 2.0f;
    const float sB = 0.005f; // originally .002
    const float sF = sB * 0.95f; // originally .62 (smaller, bigger border)
    const float zLift = 0.0008f;     // push fill toward camera so it sits over the black border
    float meanD = 0.0f; int cnt = 0;
    for (size_t y = 0; y < h; y += step)
        for (size_t x = 0; x < w; x += step) {
            float dd = depth[y*rowFloats + x];
            if (dd > 0.0f) { meanD += dd; cnt++; }
        }
    if (cnt > 0) meanD /= cnt;
    const float DEPTH_PUNCH = 1.7f;  // 1 = true metric depth; higher = more (exaggerated) relief

    // Bilinear depth at a fractional grid position; returns 0 (skip) if ANY neighbor is background,
    // so interpolated voxels never bridge the person's silhouette edge into empty space.
    auto sampleDepth = [&](float fx, float fy) -> float {
        int x0 = (int)fx, y0 = (int)fy;
        int x1 = std::min(x0 + 1, (int)w - 1), y1 = std::min(y0 + 1, (int)h - 1);
        float tx = fx - x0, ty = fy - y0;
        float d00 = depth[y0*rowFloats + x0], d10 = depth[y0*rowFloats + x1];
        float d01 = depth[y1*rowFloats + x0], d11 = depth[y1*rowFloats + x1];
        if (d00 <= 0 || d10 <= 0 || d01 <= 0 || d11 <= 0) return 0.0f;
        float a = d00*(1-tx) + d10*tx, b = d01*(1-tx) + d11*tx;
        return a*(1-ty) + b*ty;
    };

    // Camera color by normalized UV -> samples the full-res camera at the FINER grid positions.
    auto sampleCamUV = [&](float u, float v) -> ofFloatColor {
        if (!haveColor) return ofFloatColor(1.0f, 1.0f, 1.0f);
        int cx = ofClamp((int)(u * camW), 0, (int)camW - 1);
        int cy = ofClamp((int)(v * camH), 0, (int)camH - 1);
        float Y  = yCopy[cy * yStride + cx];
        int   ci = (cy/2) * cStride + (cx/2) * 2;
        float Cb = cCopy[ci] - 128.0f, Cr = cCopy[ci + 1] - 128.0f;
        return ofFloatColor(
            ofClamp((Y + 1.402f*Cr)             / 255.0f, 0.0f, 1.0f),
            ofClamp((Y - 0.344f*Cb - 0.714f*Cr) / 255.0f, 0.0f, 1.0f),
            ofClamp((Y + 1.772f*Cb)             / 255.0f, 0.0f, 1.0f));
    };

    // Finer grid: UP x the depth resolution. Depth is interpolated; color is sampled full-res.
    const int   gw = (int)((int)w * UP), gh = (int)((int)h * UP);
    const float cellB = sB / (float)UP;              // shrink cells to match the denser spacing
    const float cellF = cellB * (sF / sB);           // keep the same fill/border ratio

    // ---- glitch knobs (baked per voxel at capture) ----
    const float GLITCH_DU    = (camW > 0) ? 5.0f / (float)camW : 0.0f; // chromatic split: RGB channel offset (bigger = wilder)
    const float GLITCH_STEPS = 5.0f;                                    // posterize: levels/channel (3 = harsh, 8 = subtle)
    for (int gy = 0; gy < gh; gy++)
        for (int gx = 0; gx < gw; gx++) {
            float fx = (float)gx / UP, fy = (float)gy / UP;
            float d = sampleDepth(fx, fy);
            if (d <= 0.0f) continue;
            float ndcx = (gx/(float)gw)*2.0f - 1.0f;
            float ndcy = 1.0f - (gy/(float)gh)*2.0f;
            float zPunched = meanD + (d - meanD) * DEPTH_PUNCH;
            glm::vec3 c(ndcx*tanHalfFovY*aspect*d, ndcy*tanHalfFovY*d, -zPunched);

            // black border quad (full cell, at c.z)
            glm::vec3 b0(c.x-cellB,c.y-cellB,c.z), b1(c.x+cellB,c.y-cellB,c.z), b2(c.x+cellB,c.y+cellB,c.z), b3(c.x-cellB,c.y+cellB,c.z);
            border->addVertex(b0); border->addVertex(b1); border->addVertex(b2);
            border->addVertex(b0); border->addVertex(b2); border->addVertex(b3);

            // fill color by preset (triple-tap cycles): NORMAL = plain camera color;
            // GLITCH = chromatic split (RGB from offset UVs) + posterize.
            float u = gx/(float)gw, v = gy/(float)gh;
            ofFloatColor col;
            if (colorPreset == PRESET_GLITCH) {
                col = ofFloatColor(sampleCamUV(u+GLITCH_DU, v).r, sampleCamUV(u, v).g, sampleCamUV(u-GLITCH_DU, v).b);
                col.r = roundf(col.r*(GLITCH_STEPS-1))/(GLITCH_STEPS-1);
                col.g = roundf(col.g*(GLITCH_STEPS-1))/(GLITCH_STEPS-1);
                col.b = roundf(col.b*(GLITCH_STEPS-1))/(GLITCH_STEPS-1);
            } else {
                col = sampleCamUV(u, v);   // plain real camera color
            }
            float zf = c.z + zLift;
            glm::vec3 f0(c.x-cellF,c.y-cellF,zf), f1(c.x+cellF,c.y-cellF,zf), f2(c.x+cellF,c.y+cellF,zf), f3(c.x-cellF,c.y+cellF,zf);
            cloud->addVertex(f0); cloud->addColor(col);
            cloud->addVertex(f1); cloud->addColor(col);
            cloud->addVertex(f2); cloud->addColor(col);
            cloud->addVertex(f0); cloud->addColor(col);
            cloud->addVertex(f2); cloud->addColor(col);
            cloud->addVertex(f3); cloud->addColor(col);
        }

    // Anchor at the (copied) camera pose so camera-local points map straight into the world.
    ARAnchor *anchor = [[ARAnchor alloc] initWithTransform:camXform];
    [session addAnchor:anchor];
    anchorsWithClouds.push_back({ anchor, cloud, border, 0.0f }); // baseHue unused now (real color per voxel)
    ofLogNotice("cloud") << "placed cloud with " << cloud->getNumVertices() << " points";
}

//--------------------------------------------------------------
void ofApp::gotMemoryWarning(){
	// iOS is about to start killing apps. Drop the whole trail NOW (frees every snapshot's GPU
	// texture via shared_ptr) so we survive instead of getting jetsam'd. The budget cap should
	// normally keep us clear of this; this is the last-resort backstop for baseline growth.
	ofLogWarning("ofApp") << "memory warning -> dumping " << anchorsWithClouds.size() << " clouds";
	while (!anchorsWithClouds.empty()) removeOldestCloud();
}

//--------------------------------------------------------------
void ofApp::touchMoved(ofTouchEventArgs &touch){
    // Nothing needed — update() handles continuous placement while held (moving or stationary).
}

//--------------------------------------------------------------
void ofApp::touchUp(ofTouchEventArgs &touch){
    isTouching = false; // stop placing
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
    isTouching = false; // treat a cancelled touch like a lift
}


