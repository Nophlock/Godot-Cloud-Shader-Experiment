#[compute]
#version 450


layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

//contains the 3d image we're our outut will be stored
layout(set = 0, binding = 0, rgba32f) restrict uniform image3D OUTPUT_TEXTURE;

//contains the sampling points we are using to calculate the worley noise / distance per pixel
layout(set = 0, binding = 1, std430)  restrict buffer sample_points 
{
    float data[];
} SAMPLE_POINTS;

//the parameters 
layout(set = 0, binding = 2, std430)  restrict buffer parameters 
{
    float data[];
} PARAMETERS;

//contain all the offset to indicate where the sampling points are in our sample_points array divided by individual sampling channels
layout(set = 0, binding = 3, std430)  restrict buffer offsets 
{
    float data[];
} OFFSETS;


const int PERSISTENCE_IDX = 0;
const int INVERT_IMAGE_IDX = 1;
const int ISOLATION_IDX = 2;
const int RESOLUTION_IDX = 6;
const int SAMPLING_POINT_IDX = 9;

//all 27 neighbours possible in a 3d grid 
const ivec3 REL_NEIGHBOURS [27] = ivec3[27](
	ivec3(0,-1,0), ivec3(-1,-1,0), ivec3(1,-1,0),ivec3(0,-1,1), ivec3(0,-1,-1), //top
	ivec3(-1,-1,-1), ivec3(1,-1,-1), ivec3(-1,-1,1), ivec3(1,-1,1),

	ivec3(0,0,0), ivec3(-1,0,0), ivec3(1,0,0),ivec3(0,0,1), ivec3(0,0,-1), //center
	ivec3(-1,0,-1), ivec3(1,0,-1), ivec3(-1,0,1), ivec3(1,0,1),

	ivec3(0,1,0), ivec3(-1,1,0), ivec3(1,1,0),ivec3(0,1,1), ivec3(0,1,-1), //bottom
	ivec3(-1,1,-1), ivec3(1,1,-1), ivec3(-1,1,1), ivec3(1,1,1) 
);


//gets the sampling size for the worley meaning how many points we have scattered along our grid like 2,2,2
ivec3 get_sampling_size(int matrix_idx, int entry_idx)
{
	int idx = SAMPLING_POINT_IDX + matrix_idx * 3 + entry_idx;
	return ivec3( int (PARAMETERS.data[idx]) , int (PARAMETERS.data[idx]), int (PARAMETERS.data[idx]));
}

//gets a single sampling point (random point generated in gdscript along a grid) based on the inputs
vec3 get_sampling_point(int matrix_idx, int entry_idx, int x, int y, int z)
{
	ivec3 used_size = get_sampling_size(matrix_idx, entry_idx);

	int offset_idx = matrix_idx*3 + entry_idx;
	int offset = int(OFFSETS.data[offset_idx]);
	offset += (z * (used_size.y * used_size.x) + y * used_size.x + x ) * 3;
	
	return vec3(SAMPLE_POINTS.data[offset], SAMPLE_POINTS.data[offset+1], SAMPLE_POINTS.data[offset+2]);
}	


//wrap the points around the other site of our points if we are outside of our grid. The wraping allows the image to seamlessly repeat in the end
vec3 get_warped_sample_point(ivec3 img_dim, int matrix_idx, int idx, int x, int y, int z)
{
	ivec3 used_size = get_sampling_size(matrix_idx, idx);
	vec3 wrap_offset = vec3(0.0f, 0.0f, 0.0f);
	
	int safe_ix = x;
	int safe_iy = y;
	int safe_iz = z;
	
	if (x < 0)
	{
		safe_ix = used_size.x + x;
		wrap_offset.x = -img_dim.x;
	}
	else if (x >= used_size.x)
	{
		safe_ix = x - used_size.x;	
		wrap_offset.x = img_dim.x;
	}
	
	if (y < 0)
	{
		safe_iy = used_size.y + y;
		wrap_offset.y = -img_dim.y;
	}
	else if (y >= used_size.y)
	{
		safe_iy = y - used_size.y;	
		wrap_offset.y = img_dim.y;
	}
	
	if (z < 0)
	{
		safe_iz = used_size.z + z;
		wrap_offset.z = -img_dim.z;
	}
	else if (z >= used_size.z)
	{
		safe_iz = z - used_size.z;	
		wrap_offset.z = img_dim.z;
	}

	
	
	vec3 safe_pos = get_sampling_point(matrix_idx, idx, safe_ix, safe_iy, safe_iz);

	return safe_pos + wrap_offset;
}

//squared distance of two points
float get_distance_squared(vec3 a, vec3 b)
{
	vec3 rel = a-b;
	return dot(rel,rel);
}

//calculate the color of one pixel for a single worley noise
float calculate_pixel(int matrix_idx, int column, ivec3 c_pos, ivec3 img_dim)
{
	ivec3 point_size = get_sampling_size(matrix_idx, column);
	vec3 grid_size = vec3(img_dim) / vec3(point_size);
	vec3 fc_pos = vec3(c_pos);
	
	ivec3 c_grid = ivec3( (fc_pos / grid_size) );
	
	vec3 closest_point = fc_pos;
	
	float furthest_distance = length(grid_size);
	float closest_distance = 9999999999.0f;
	
	for (int i = 0; i < 27; i++)
	{
		ivec3 idx = c_grid + REL_NEIGHBOURS[i];
		
		vec3 grid_point = get_warped_sample_point(img_dim, matrix_idx, column, idx.x, idx.y, idx.z);
		float new_dist = get_distance_squared(fc_pos, grid_point);
		
		if (new_dist < closest_distance)
		{
			closest_distance = new_dist;
			closest_point = grid_point;
		}
	}

	return 1.0f - (distance(fc_pos, closest_point) / furthest_distance);
}

//calculate the color of one pixel as a set of three worley noised combined to one
float calculate_convoluted_pixel(int matrix_idx, ivec3 c_pos, ivec3 img_dim)
{
	float persistence = PARAMETERS.data[PERSISTENCE_IDX];
	
	float min_dist_1 = calculate_pixel(matrix_idx, 0, c_pos, img_dim);
	float min_dist_2 = calculate_pixel(matrix_idx, 1, c_pos, img_dim);
	float min_dist_3 = calculate_pixel(matrix_idx, 2, c_pos, img_dim);
	float total_dist = mix( mix(min_dist_1, min_dist_2, persistence), min_dist_3, persistence);
	
	
	return total_dist;
}


void main() 
{
	ivec3 coords = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 img_coords = coords;
	
	ivec3 dimensions = imageSize(OUTPUT_TEXTURE);
	
	float img_invert = PARAMETERS.data[INVERT_IMAGE_IDX];
	
	
	if (img_invert >= 1.0f)
	{
		coords = (dimensions - ivec3(1,1,1)) - coords;
	}
	
	
	vec4 pixel = vec4(1.0f);
	pixel.r = calculate_convoluted_pixel(0, coords, dimensions);
	pixel.g = calculate_convoluted_pixel(1, coords, dimensions);
	pixel.b = calculate_convoluted_pixel(2, coords, dimensions);
	pixel.a = calculate_convoluted_pixel(3, coords, dimensions);
	
	if (PARAMETERS.data[ISOLATION_IDX+0] >= 1.0f)
	{
		pixel.g = pixel.r;
		pixel.b = pixel.r;
		pixel.a = 1.0f;
	}
	else if (PARAMETERS.data[ISOLATION_IDX+1] >= 1.0f)
	{
		pixel.r = pixel.g;
		pixel.b = pixel.g;
		pixel.a = 1.0f;
	}
	else if (PARAMETERS.data[ISOLATION_IDX+2] >= 1.0f)
	{
		pixel.r = pixel.b;
		pixel.g = pixel.b;
		pixel.a = 1.0f;
	}
	else if (PARAMETERS.data[ISOLATION_IDX+3] >= 1.0f)
	{
		pixel.r = pixel.a;
		pixel.g = pixel.a;
		pixel.b = pixel.a;
		pixel.a = 1.0f;
	}
	
	
	imageStore(OUTPUT_TEXTURE, img_coords, pixel);
}