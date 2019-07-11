/* platform.h - Copyright 2019 Utrecht University

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

	   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

   This file:

   Platform-specific header-, class- and function declarations.
*/

#pragma once

// GLFW
#define GLFW_EXPOSE_NATIVE_WGL

// system includes
#include <glad/glad.h>
#include <GLFW/glfw3.h>
#include <GLFW/glfw3native.h>
#include <vector>
#include <string>
#include <algorithm>
#include "zlib.h"
#include "emmintrin.h"
#include <assert.h>
#include "freeimage.h"

// namespaces
using namespace std;

// include system-wide functionality
#include "system.h"

namespace lighthouse2 {

class Shader
{
public:
	// constructor / destructor
	Shader( const char* vfile, const char* pfile );
	~Shader();
	// methods
	void Init( const char* vfile, const char* pfile );
	void Compile( const char* vtext, const char* ftext );
	void Bind();
	void SetInputTexture( uint slot, const char* name, GLTexture* texture );
	void SetInputMatrix( const char* name, const mat4& matrix );
	void SetFloat( const char* name, const float v );
	void SetInt( const char* name, const int v );
	void SetUInt( const char* name, const uint v );
	void Unbind();
private:
	// data members
	uint vertex = 0;	// vertex shader identifier
	uint pixel = 0;		// fragment shader identifier
	// public data members
	uint ID = 0;		// shader program identifier
};

} // namespace lighthouse2

// forward declarations of platform-specific helpers
void _CheckGL( char* f, int l );
#define CheckGL() { _CheckGL( __FILE__, __LINE__ ); }
GLuint CreateVBO( const GLfloat* data, const uint size );
void BindVBO( const uint idx, const uint N, const GLuint id );
void CheckShader( GLuint shader, const char* vshader, const char* fshader );
void CheckProgram( GLuint id, const char* vshader, const char* fshader );
void DrawQuad();

// EOF