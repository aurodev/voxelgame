/******************************************************
This shader blends two separate top and side textures, each with their own triplanar mapped albedo, normal and ambient occlusion.

Texture A is the top surface.
Texture B are the sides and bottom.

The typical use case would be to have grass on top and a rocky surface on the sides and bottom of a terrain.

This version of the shader shows an obvious repeating pattern when wide, flat areas are textured. This is inevitable when stamping
the same texture over and over. Version 2 of this shader fixes this issue at the cost of additional texture lookups.

Last modified: 2019-11-30

******************************************************/

shader_type spatial;
render_mode blend_mix,depth_draw_opaque,cull_back,diffuse_burley,specular_schlick_ggx;

uniform float 		AB_mix_offset : hint_range(-20., 0.) = -50;
uniform float 		AB_mix_normal : hint_range(0., 10.) = 10;
uniform float 		AB_mix_blend : hint_range(0., 10.) = 2.;

uniform bool		A_albedo_enabled = true;
uniform vec4 		A_albedo_tint : hint_color = vec4(1., 1., 1., 1.);
uniform sampler2D 	A_albedo_map : hint_albedo;

uniform bool		A_normal_enabled = true;
uniform sampler2D 	A_normal_map : hint_normal;
uniform float 		A_normal_strength : hint_range(-16., 16.0) = 1.;

uniform vec4 		A_ao_tex_channel = vec4(.33, .33, .33, 0.);		// Use only one channel: Red, Green, Blue, Alpha
uniform bool		A_ao_enabled = true;
uniform float 		A_ao_strength : hint_range(-1., 1.0) = 1.; 
uniform sampler2D 	A_ao_map : hint_white;

uniform vec3 		A_uv_offset;
uniform int 		A_uv_tiles : hint_range(1, 16) = 1;
uniform float 		A_tri_blend_sharpness : hint_range(0.001, 50.0) = 50.;

uniform bool		B_albedo_enabled = true;
uniform vec4 		B_albedo_tint : hint_color = vec4(1., 1., 1., 1.);
uniform sampler2D 	B_albedo_map : hint_albedo;

uniform bool		B_normal_enabled = true;
uniform sampler2D 	B_normal_map : hint_normal;
uniform float 		B_normal_strength : hint_range(-16., 16.0) = 1.;

uniform vec4 		B_rough_tex_channel = vec4(.33, .33, .33, 0.);		// Use only one channel: Red, Green, Blue, Alpha
uniform bool		B_rough_enabled = true;
uniform float 		B_rough_min : hint_range(0, 1) = .1;
uniform float 		B_rough_max : hint_range(0, 1) = .75;
uniform float 		B_rough_distance : hint_range(.0005, 10.) = .1;
uniform sampler2D 	B_rough_map : hint_white;
uniform float 		B_fresnel_bias	= 0.;
uniform float 		B_fresnel_scale	= 1.0;
uniform float 		B_fresnel_power	: hint_range(0., 20.) = 4.0;
varying float 		B_fresnel;
uniform float 		B_specular : hint_range(0., 1.)	= 0.5;

uniform vec4 		B_ao_tex_channel = vec4(.33, .33, .33, 0.);		// Use only one channel: Red, Green, Blue, Alpha
uniform bool		B_ao_enabled = true;
uniform float 		B_ao_strength : hint_range(-1., 1.0) = 1.; 
uniform sampler2D 	B_ao_map : hint_white;

uniform vec3 		B_uv_offset;
uniform int 		B_uv_tiles : hint_range(1, 16) = 1;
uniform float 		B_tri_blend_sharpness : hint_range(0.001, 50.0) = 50.;

varying vec3 		A_uv_triplanar_pos;
varying vec3 		A_uv_power_normal;
varying vec3 		B_uv_triplanar_pos;
varying vec3 		B_uv_power_normal;

varying vec3 		vertex_normal;
varying float		vertex_distance;
varying vec3 		vertex_pos;
varying vec3 		camera_pos;



vec4 triplanar_texture(sampler2D p_sampler, vec3 p_weights, vec3 p_triplanar_pos) {
        vec4 samp=vec4(0.0);
        samp+= texture(p_sampler,p_triplanar_pos.xy) * p_weights.z;
        samp+= texture(p_sampler,p_triplanar_pos.xz) * p_weights.y;
        samp+= texture(p_sampler,p_triplanar_pos.zy * vec2(-1.0,1.0)) * p_weights.x;
        return samp;
}


void vertex() {
    TANGENT = vec3(0.0,0.0,-1.0) * abs(NORMAL.x);
    TANGENT+= vec3(1.0,0.0,0.0) * abs(NORMAL.y);
    TANGENT+= vec3(1.0,0.0,0.0) * abs(NORMAL.z);
    TANGENT = normalize(TANGENT);
    BINORMAL = vec3(0.0,1.0,0.0) * abs(NORMAL.x);
    BINORMAL+= vec3(0.0,0.0,-1.0) * abs(NORMAL.y);
    BINORMAL+= vec3(0.0,1.0,0.0) * abs(NORMAL.z);
    BINORMAL = normalize(BINORMAL);

    A_uv_power_normal=pow(abs(NORMAL),vec3(A_tri_blend_sharpness));
    A_uv_power_normal/=dot(A_uv_power_normal,vec3(1.0));
    A_uv_triplanar_pos = VERTEX * float(A_uv_tiles) / (16.) + A_uv_offset;			//On VoxelTerrain 16 is 100% size, so uv_tile is multiples of 16. 
	A_uv_triplanar_pos *= vec3(1.0,-1.0, 1.0);
	
    B_uv_power_normal=pow(abs(NORMAL),vec3(B_tri_blend_sharpness));
    B_uv_power_normal/=dot(B_uv_power_normal,vec3(1.0));
    B_uv_triplanar_pos = VERTEX * float(B_uv_tiles) / (16.)  + B_uv_offset;
	B_uv_triplanar_pos *= vec3(1.0,-1.0, 1.0);
	

	// Get the distance from camera to VERTEX (VERTEX as if the camera is 0,0,0)
	vertex_distance = (PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;		// w/o vertex_world_coords (faster than length())

	vertex_pos = (WORLD_MATRIX * vec4(VERTEX,1.0)).xyz;		// Global vertex position
	camera_pos = CAMERA_MATRIX[3].xyz;						// Global camera position

	vertex_normal = normalize(NORMAL);	

	// Fresnel calculation
	// R = max(0, min(1, bias + scale * (1.0 + I • N)power))
	// R is a Fresnel term describing how strong the Fresnel effect is at a specific point
	// I is the vector from the eye to a point on the surface
	// N is the world space normal of the current point
	// bias, scale and power are values exposed to allow control over the appearance of the Fresnel effect
	B_fresnel = B_fresnel_bias + B_fresnel_scale * pow(1.0 + dot(normalize(vertex_pos-camera_pos), vertex_normal), B_fresnel_power);
	
}


void fragment() {
	
	// Calculate Albedo 
	
	vec3 A_albedo, B_albedo;
	float AB_mix_factor;
	if(A_albedo_enabled) {
		ALBEDO = A_albedo = A_albedo_tint.rgb * triplanar_texture(A_albedo_map,A_uv_power_normal,A_uv_triplanar_pos).rgb;
		AB_mix_factor = clamp( AB_mix_normal*dot(vec3(0.,1.,0.), vertex_normal) + AB_mix_offset + AB_mix_blend*A_albedo.g, 0., 1.);
	}
	if(B_albedo_enabled) {
		ALBEDO = B_albedo = B_albedo_tint.rgb * triplanar_texture(B_albedo_map,B_uv_power_normal,B_uv_triplanar_pos).rgb;
	}
	if(A_albedo_enabled==true && B_albedo_enabled==true) {
		ALBEDO = mix(B_albedo, A_albedo, AB_mix_factor);
	}


	// Calculate Roughness, fresnel, specular - Only used for B/Rock
		
	float roughness_tex = dot(triplanar_texture(B_rough_map,B_uv_power_normal,B_uv_triplanar_pos),B_rough_tex_channel);
	if(B_rough_enabled) {
		float B_rough;
		ROUGHNESS = B_rough = clamp(roughness_tex * B_fresnel,  
						clamp(B_rough_distance*vertex_distance*B_rough_min, B_rough_min, B_rough_max),
					B_rough_max);
		//	ROUGHNESS = clamp(roughness_tex * (B_rough_distance * log(vertex_distance)), );
		if(A_albedo_enabled==true) {
			ROUGHNESS = mix(B_rough, 1.0, AB_mix_factor);
		}
		SPECULAR = B_specular;
	}


	// Calculate Normals
	
	vec3 A_normal=vec3(0.5,0.5,0.5);
	vec3 B_normal=vec3(0.5,0.5,0.5);	
	if(A_normal_enabled)
		A_normal = triplanar_texture(A_normal_map,A_uv_power_normal,A_uv_triplanar_pos).rgb;
	if(B_normal_enabled)
		B_normal = triplanar_texture(B_normal_map,B_uv_power_normal,B_uv_triplanar_pos).rgb;
	if(A_normal_enabled || B_normal_enabled) {
		NORMALMAP = mix(B_normal, A_normal, AB_mix_factor);
		NORMALMAP_DEPTH = mix(B_normal_strength, A_normal_strength, AB_mix_factor);
	}


	// Calculate Ambient Occlusion
	
	float A_ao=1., B_ao=1.;
	if(A_ao_enabled) 
		AO = A_ao = dot(triplanar_texture(A_ao_map,A_uv_power_normal,A_uv_triplanar_pos),A_ao_tex_channel);
	if(B_ao_enabled)
		AO = B_ao = dot(triplanar_texture(B_ao_map,B_uv_power_normal,B_uv_triplanar_pos),B_ao_tex_channel);
	if(A_ao_enabled || B_ao_enabled) {
		AO = mix(B_ao, A_ao, AB_mix_factor);
		AO_LIGHT_AFFECT = mix(B_ao_strength, A_ao_strength, AB_mix_factor);
	}

	
}

