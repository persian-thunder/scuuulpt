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

    img.load("OpenFrameworks.png");

    int fontSize = 8;
    if (ofxiOSGetOFWindow()->isRetinaSupportedOnDevice())
        fontSize *= 2;

    font.load("fonts/mono0755.ttf", fontSize);

    processor = ARProcessor::create(session);
    processor->setup();

    // Minimal GLES2 point shader: oF's default shaders don't set gl_PointSize, so without this
    // the cloud renders as 1px specks. position/color are bound automatically from the ofVboMesh.
    string pointVert =
        "uniform mat4 modelViewProjectionMatrix;\n"
        "uniform float pointSize;\n"
        "attribute vec4 position;\n"
        "attribute vec4 color;\n"
        "varying vec4 vColor;\n"
        "void main(){ gl_Position = modelViewProjectionMatrix * position; gl_PointSize = pointSize; vColor = color; }\n";
    string pointFrag =
        "precision highp float;\n"
        "varying vec4 vColor;\n"
        "void main(){ gl_FragColor = vColor; }\n";
    pointShader.setupShaderFromSource(GL_VERTEX_SHADER, pointVert);
    pointShader.setupShaderFromSource(GL_FRAGMENT_SHADER, pointFrag);
    pointShader.linkProgram();

    // Cloud shader (triangles — this path renders on this ES2 device). Per vertex we pass the
    // baked data in color: r = depth brightness, g = per-cloud base hue. texcoord = quad-local UV
    // (-1..1) for a soft round glow. The fragment animates the hue over time and does the glow.
    string cloudVert =
        "uniform mat4 modelViewProjectionMatrix;\n"
        "attribute vec4 position;\n"
        "attribute vec4 color;\n"
        "attribute vec2 texcoord;\n"
        "varying vec4 vColor;\n"
        "varying vec2 vUv;\n"
        "void main(){ gl_Position = modelViewProjectionMatrix * position; vColor = color; vUv = texcoord; }\n";
    string cloudFrag =
        "precision highp float;\n"
        "varying vec4 vColor;\n"
        "varying vec2 vUv;\n"
        "uniform float u_time;\n"
        "vec3 hsb2rgb(vec3 c){\n"
        "  vec3 rgb = clamp(abs(mod(c.x*6.0 + vec3(0.0,4.0,2.0),6.0)-3.0)-1.0, 0.0, 1.0);\n"
        "  return c.z * mix(vec3(1.0), rgb, c.y);\n"
        "}\n"
        "void main(){\n"
        "  float hue = fract(vColor.g + u_time*0.15);\n"          // baked per-cloud hue, rotating in time
        "  float bright = 0.4 + 0.6*vColor.r;\n"                  // depth brightness
        "  vec3 rgb = hsb2rgb(vec3(hue, 0.9, bright));\n"
        "  gl_FragColor = vec4(rgb, 1.0);\n"                      // DIAGNOSTIC: solid, no glow/discard
        "}\n";
    cloudShader.setupShaderFromSource(GL_VERTEX_SHADER, cloudVert);
    cloudShader.setupShaderFromSource(GL_FRAGMENT_SHADER, cloudFrag);
    cloudShader.linkProgram();
}



//--------------------------------------------------------------
void ofApp::update(){
	//allocate FBO
	if (!fboAllocated) {
		bodyFbo.allocate(ofGetWidth(), ofGetHeight());
		fboAllocated = true;
	}


    processor->update();


    // NOTE: depth is now read only at CAPTURE time (placeCloudAnchor), not per frame. The old
    // per-frame depth preview re-uploaded a texture every frame, churning the GPU and pressuring
    // the fragile Metal camera texture cache (the MetalCam:203 crash). Removed for stability.
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

            // Animated color WITHOUT a custom shader (those don't render here): each cloud keeps a
            // base hue, tinted live via ofSetColor(fromHsb(baseHue + time)) through the default shader.
            // ALPHA blend (not additive) so overlapping clouds composite by color instead of summing
            // to white; depth test ON so nearer clouds occlude farther ones (readable 3D layering).
            ofEnableBlendMode(OF_BLENDMODE_ALPHA);
            ofEnableDepthTest();
            float t = ofGetElapsedTimef();
            for (auto& ac : anchorsWithClouds) {
                if (!ac.anchor || !ac.cloud) continue;
                ofPushMatrix();
                ofMatrix4x4 mat = convert<matrix_float4x4, ofMatrix4x4>(ac.anchor.transform);
                ofMultMatrix(mat);
                ofSetColor(0);                                            // black border cells
                if (ac.border) ac.border->draw();
                float hue = fmodf(ac.baseHue + t * 0.15f, 1.0f);         // animated hue
                ofSetColor(ofFloatColor::fromHsb(hue, 0.85f, 1.0f));
                ac.cloud->draw();                                        // colored fill on top
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
    // Build ONE depth point cloud per tap, in the touch event (between frames) — the safe time to
    // read GPU/AR resources. The cloud is uploaded once and then drawn as static geometry.
    placeCloudAnchor();
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
    frame = nil;                                          // stop referencing ARKit's frame now

    if (depth.empty()) return;

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

    // Per-cloud base hue, captured at placement. draw() animates it over time via ofSetColor,
    // so no custom shader is needed (those don't render on this device). Geometry only here.
    float placementHue = fmodf(ofGetElapsedTimef() * (1.0f/12.0f), 1.0f);

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

            // colored fill quad (smaller, nudged toward camera so it covers the border's center)
            float zf = c.z + zLift;
            glm::vec3 f0(c.x-sF,c.y-sF,zf), f1(c.x+sF,c.y-sF,zf), f2(c.x+sF,c.y+sF,zf), f3(c.x-sF,c.y+sF,zf);
            cloud->addVertex(f0); cloud->addVertex(f1); cloud->addVertex(f2);
            cloud->addVertex(f0); cloud->addVertex(f2); cloud->addVertex(f3);
        }

    // Anchor at the (copied) camera pose so camera-local points map straight into the world.
    ARAnchor *anchor = [[ARAnchor alloc] initWithTransform:camXform];
    [session addAnchor:anchor];
    anchorsWithClouds.push_back({ anchor, cloud, border, placementHue });
    ofLogNotice("cloud") << "placed cloud with " << cloud->getNumVertices() << " points";
}

//--------------------------------------------------------------
void ofApp::gotMemoryWarning(){
	// iOS is about to start killing apps. Drop the whole trail NOW (frees every snapshot's GPU
	// texture via shared_ptr) so we survive instead of getting jetsam'd. The budget cap should
	// normally keep us clear of this; this is the last-resort backstop for baseline growth.
	ofLogWarning("ofApp") << "memory warning -> dumping " << anchorsWithFBOs.size()
	                      << " FBOs + " << anchorsWithClouds.size() << " clouds";
	while (!anchorsWithFBOs.empty())   removeOldestAnchor();
	while (!anchorsWithClouds.empty()) removeOldestCloud();
}

//--------------------------------------------------------------
void ofApp::touchMoved(ofTouchEventArgs &touch){
    // Hold + drag to place continuously, but THROTTLED. touchMoved fires dozens of times a
    // second; placing on every one allocates FBOs faster than the GPU frees them and blows past
    // 1 GB. Cap it to ~10 placements/sec — still a smooth continuous trail, bounded memory.
    float now = ofGetElapsedTimef();
    if(now - lastPlaceTime > 0.1f){   // ~10 clouds/sec on drag
        lastPlaceTime = now;
        placeCloudAnchor();
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


