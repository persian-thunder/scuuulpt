#include "ofApp.h"
#include <cstddef>

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
    // NOTE: setHighRes(false)/720p garbles the camera image — MetalCam.mm hardcodes 1920x1440 for its
    // conversion/matte buffers, so a different video size = stride mismatch. Stay at 1080p.
    this->session = generateNewSession(format);
}

//--------------------------------------------------------------
ofApp :: ~ofApp () {
    cout << "destroying ofApp" << endl;
}

//--------------------------------------------------------------
void ofApp::setup() {
	ofClear(0,0,0,0);

    int fontSize = 8;
    if (ofxiOSGetOFWindow()->isRetinaSupportedOnDevice())
        fontSize *= 2;
    font.load("fonts/mono0755.ttf", fontSize);

    processor = ARProcessor::create(session);
    processor->setup();
}



//--------------------------------------------------------------
void ofApp::update(){
    processor->update();

    // Press & hold to paint: while a finger is down, place on a throttle (moving or not). iOS gives
    // no repeating "held" touch event, so we drive it from update(). Depth is only read here at these
    // throttled placements, not every frame, so it doesn't churn the Metal camera cache.
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
	ofClear(0,0,0, 0);
    ofEnableAlphaBlending();

    //ofDisableDepthTest();

    // ---- Camera background ----
    // Reuse the already-converted full-color (BGRA) camera texture that the segmentation path
    // produces — wrap its GL id in an ofTexture and draw it fullscreen behind everything. No second
    // camera pipeline is started, so there's no status=77 conflict like processor->draw() caused.
    CVOpenGLESTextureRef camTex = processor->getCameraTexture();
    if (camTex) {
        GLuint texID = CVOpenGLESTextureGetName(camTex);
        ofTexture bg;
        bg.setUseExternalTextureID(texID);                               // don't let oF delete/realloc it
        bg.texData.textureTarget    = CVOpenGLESTextureGetTarget(camTex); // GL_TEXTURE_2D
        bg.texData.width  = bg.texData.tex_w = ofGetWidth();
        bg.texData.height = bg.texData.tex_h = ofGetHeight();
        bg.texData.tex_u  = bg.texData.tex_t = 1.0f;                      // normalized coords for TEXTURE_2D
        bg.texData.glInternalFormat = GL_RGBA;
        bg.texData.bFlipTexture = false;                                 // texture already in oF's orientation
        bg.texData.bAllocated = true;
        ofSetColor(255);
        bg.draw(0, 0, ofGetWidth(), ofGetHeight());
    }

    // Live segmentation cutout removed — the point cloud replaced it, and its matte pipeline is
    // the fragile per-frame Metal work we're disabling to stop the ~4s EXC_BREAKPOINT.
    // processor->drawCameraDebugPersonSegmentation();

    if (session.currentFrame){
        if (session.currentFrame.camera){
            camera.begin();
            processor->setARCameraMatrices();

            // Voxels wear the REAL camera color baked per vertex at capture. ALPHA blend + depth
            // test so overlapping clouds composite by color and nearer ones occlude farther ones.
            ofEnableBlendMode(OF_BLENDMODE_ALPHA);
            ofEnableDepthTest();
            for (auto& ac : anchorsWithClouds) {
                if (!ac.anchor || !ac.cloud) continue;
                ofPushMatrix();
                ofMatrix4x4 mat = convert<matrix_float4x4, ofMatrix4x4>(ac.anchor.transform);
                ofMultMatrix(mat);
                ofSetColor(0);                     // black border cells
                if (ac.border) ac.border->draw();
                ofSetColor(255);                   // white tint -> real per-voxel camera colors show
                ac.cloud->draw();                  // colored fill on top
                ofPopMatrix();
            }
            ofSetColor(255);

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
    // Place one immediately, then update() keeps placing while the finger stays down (press & hold).
    isTouching = true;
    placeCloudAnchor();
    lastPlaceTime = ofGetElapsedTimef();
}

void ofApp::removeOldestCloud(){
	if (!anchorsWithClouds.empty()){
		[session removeAnchor:anchorsWithClouds.front().anchor];
		anchorsWithClouds.erase(anchorsWithClouds.begin()); // shared_ptr frees the VBO
	}
}

//--------------------------------------------------------------
// Build a point cloud ONCE from the current depth frame and anchor it. Camera-local meters; drawn
// later at the anchor's world transform. ~12k points * 16 bytes ~= 200 KB each (vs ~3 MB per FBO).
void ofApp::placeCloudAnchor(){
    if (!session.currentFrame || !session.currentFrame.estimatedDepthData) return;

    while (anchorsWithClouds.size() >= (size_t)MAX_TRAIL_COUNT) removeOldestCloud();

    // ---- Grab what we need from the ARFrame FAST, then let it go. Holding ARKit's depth buffer /
    // frame across the long build loop races with ARKit recycling frames on its SLAM thread
    // (EXC_BAD_ACCESS 0x18 in the camera texture path). So: copy the depth grid + pose into locals,
    // unlock + drop the frame IMMEDIATELY, then build from the copy with no ARKit buffers held.
    ARFrame *frame = session.currentFrame;
    matrix_float4x4 camXform = frame.camera.transform;   // value copy of the pose
    CVPixelBufferRef depthMap = frame.estimatedDepthData;

    CVPixelBufferLockBaseAddress(depthMap, kCVPixelBufferLock_ReadOnly);
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
    const int   step = 1;            // ~256x192 -> ~5k points
    const float tanHalfFovY = 0.7f;  // rough pinhole; tune if scale looks off
    const float aspect = (float)w / (float)h;
    const float RANGE = 2.0f;
    const float sB = 0.002f;         // border half-size (full cell)
    const float sF = sB * 0.62f;     // fill half-size (smaller -> leaves black border)
    const float zLift = 0.0008f;     // push fill toward camera so it sits over the black border
    float meanD = 0.0f; int cnt = 0;
    for (size_t y = 0; y < h; y += step)
        for (size_t x = 0; x < w; x += step) {
            float dd = depth[y*rowFloats + x];
            if (dd > 0.0f) { meanD += dd; cnt++; }
        }
    if (cnt > 0) meanD /= cnt;
    const float DEPTH_PUNCH = 3.0f;  // 1 = flat; higher = more dramatic relief

    // Sample the REAL camera color for a depth-grid cell: scale coords to camera res, full-range
    // YCbCr -> RGB. Falls back to white if no camera image this frame.
    auto sampleCam = [&](int dx, int dy) -> ofFloatColor {
        if (!haveColor) return ofFloatColor(1.0f, 1.0f, 1.0f);
        int cx = ofClamp(dx * (int)camW / (int)w, 0, (int)camW - 1);
        int cy = ofClamp(dy * (int)camH / (int)h, 0, (int)camH - 1);
        float Y  = yCopy[cy * yStride + cx];
        int   ci = (cy/2) * cStride + (cx/2) * 2;
        float Cb = cCopy[ci]     - 128.0f;
        float Cr = cCopy[ci + 1] - 128.0f;
        return ofFloatColor(
            ofClamp((Y + 1.402f*Cr)             / 255.0f, 0.0f, 1.0f),
            ofClamp((Y - 0.344f*Cb - 0.714f*Cr) / 255.0f, 0.0f, 1.0f),
            ofClamp((Y + 1.772f*Cb)             / 255.0f, 0.0f, 1.0f));
    };

    for (size_t y = 0; y < h; y += step)
        for (size_t x = 0; x < w; x += step) {
            float d = depth[y*rowFloats + x];
            if (d <= 0.0f) continue;
            float ndcx = (x/(float)w)*2.0f - 1.0f;
            float ndcy = 1.0f - (y/(float)h)*2.0f;
            float zPunched = meanD + (d - meanD) * DEPTH_PUNCH;
            glm::vec3 c(ndcx*tanHalfFovY*aspect*d, ndcy*tanHalfFovY*d, -zPunched);

            // black border quad (full cell, at c.z)
            glm::vec3 b0(c.x-sB,c.y-sB,c.z), b1(c.x+sB,c.y-sB,c.z), b2(c.x+sB,c.y+sB,c.z), b3(c.x-sB,c.y+sB,c.z);
            border->addVertex(b0); border->addVertex(b1); border->addVertex(b2);
            border->addVertex(b0); border->addVertex(b2); border->addVertex(b3);

            // colored fill quad (smaller, nudged toward camera so it covers the border's center),
            // wearing the real camera color it captured.
            ofFloatColor col = sampleCam((int)x, (int)y);
            float zf = c.z + zLift;
            glm::vec3 f0(c.x-sF,c.y-sF,zf), f1(c.x+sF,c.y-sF,zf), f2(c.x+sF,c.y+sF,zf), f3(c.x-sF,c.y+sF,zf);
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


