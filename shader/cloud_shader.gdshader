shader_type spatial;
render_mode unshaded;//cull_disabled note if you want to go through the clodes enable it, but this will cost more performance due to duplicate pixels

group_uniforms Automatic_Do_Not_Touch;

uniform vec4 MAIN_LIGHT_COLOR = vec4(1.0);
uniform vec3 MAIN_LIGHT_POSITION = vec3(0.0);
uniform float MAIN_LIGHT_ENERGY = 1.0f;
uniform float MAIN_LIGHT_INDIRECT_ENERGY = 1.0f;

uniform vec3 BBOX_MIN = vec3(-0.25,-0.25,-0.25);
uniform vec3 BBOX_MAX = vec3(0.25,0.25,0.35);


uniform sampler3D DENSITY_MAP : repeat_enable;
uniform sampler3D DETAILED_DENSITY_MAP : repeat_enable;

group_uniforms LIGHT_SETTINGS;
uniform float LIGHT_SUN_ABSORPTION = 1.0f;
uniform float LIGHT_VIEWER_ABSORPTION = 1.0f;
uniform float DARKNESS_THRESHOLD = 1.0f;
uniform float PHASE_VALUE = 1.0f;


group_uniforms SHADER_RESOLUTION;
uniform float CLOUD_RESOLUTION = 10.0f;
uniform float LIGHT_RESOLUTION = 8.0f;

group_uniforms CLOUD_SETTINGS;
uniform float CLOUD_SCALE = 1.0f;
uniform float CLOUD_DETAIL_SCALE = 1.0f;
uniform vec3 CLOUD_OFFSET = vec3(0.0f);

uniform vec4 NOISE_WEIGHT = vec4(1.0f);
uniform vec4 DETAILED_NOISE_WEIGHT = vec4(1.0f);

uniform float DENSITY_MULTIPLIER = 5.0f;
uniform float DENSITY_OFFSET = 0.0f;
uniform float OFFSET_SPEED = 1.0f;

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, repeat_disable, filter_nearest;
uniform sampler2D DEPTH_TEXTURE : source_color, hint_depth_texture;


vec2 get_ray_bbox_intersection(vec3 ray_origin, vec3 ray_dir, vec3 box_min, vec3 box_max)
{
	vec3 t0 = (box_min - ray_origin) / ray_dir;
	vec3 t1 = (box_max - ray_origin) / ray_dir;
	
	vec3 tmin = min(t0,t1);
	vec3 tmax = max(t0,t1);
	
	float dist_a = max(max(tmin.x,tmin.y),tmin.z);
	float dist_b = min(tmax.x,min(tmax.y, tmax.z));
	
	float dist_to_box = max(0, dist_a);
	float dist_inside_box = max(0, dist_b - dist_to_box);
	
	return vec2(dist_to_box, dist_inside_box);
}

float sample_density(vec3 position)
{
	vec3 uvw = position * CLOUD_SCALE * 0.01f;
	vec3 shape_sample_pos = uvw + CLOUD_OFFSET * OFFSET_SPEED;
	
	vec4 shape_noise = texture(DENSITY_MAP, shape_sample_pos);
	vec4 normalize_shape_noise_weight = (NOISE_WEIGHT / dot(NOISE_WEIGHT, vec4(1.0) ));
	
	float shape_fbm = dot(shape_noise, normalize_shape_noise_weight);
	float base_shape_density = shape_fbm + DENSITY_OFFSET * 0.1f;
	
	if (base_shape_density > 0.0f)
	{
		vec3 detailed_sample_pos = uvw * CLOUD_DETAIL_SCALE * OFFSET_SPEED;
		
		vec4 detailed_noise = texture(DETAILED_DENSITY_MAP, detailed_sample_pos);
		vec4 normalized_detail_weight = DETAILED_NOISE_WEIGHT / dot(DETAILED_NOISE_WEIGHT, vec4(1.0) );
		
		float detailed_fbm = dot(detailed_noise, normalized_detail_weight);
		
		float detail_erode_weight = shape_fbm * shape_fbm * shape_fbm;
		float detail_value = 1.0 - (detail_erode_weight * detailed_fbm);
		
		float cloud_density = base_shape_density - detail_value;
		
		return cloud_density * DENSITY_MULTIPLIER;
	}
	
	return 0.0f;
}

float sample_light_density(vec3 start_position)
{
	vec3 light_dir = (start_position - MAIN_LIGHT_POSITION);
	float light_dist = length(light_dir);
	
	light_dir /= -light_dist;
	
	float light_coef = (16.0f / MAIN_LIGHT_ENERGY);	
	light_dist = light_dist * light_coef * 0.1f;
	
	vec2 ray_info = get_ray_bbox_intersection(start_position, light_dir, BBOX_MIN, BBOX_MAX);
	
	float box_density = ray_info.y;
	float step_size = box_density / LIGHT_RESOLUTION;
	
	float light_density = 0.0f;
	
	for (float i = 0.0f; i <= LIGHT_RESOLUTION; i+=1.0f)
	{
		vec3 sample_light_position = start_position + (light_dir * step_size * i);
		light_density += max(0.0f, sample_density(sample_light_position) * step_size  );
	}
	
	float transmitance = exp(-light_density * LIGHT_SUN_ABSORPTION * light_dist) * MAIN_LIGHT_INDIRECT_ENERGY;
	
	return DARKNESS_THRESHOLD + transmitance * (1.0 - DARKNESS_THRESHOLD);
} 

void fragment() 
{
	vec3 ray_origin = CAMERA_POSITION_WORLD;
	vec3 ray_dir = -(INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz; //convert to world space and inverse since it is fragment to cam
	
	vec2 ray_info = get_ray_bbox_intersection(ray_origin, ray_dir, BBOX_MIN, BBOX_MAX);
	
	float ray_box_start = ray_info.x;
	float ray_box_length = ray_info.y;
	
	if (ray_box_length > 0.0f)
	{
		vec3 entry_point = ray_origin + ray_dir * ray_box_start;
		
		float number_of_steps = ray_box_length / CLOUD_RESOLUTION;
		float light_energy = 0.0;
		float transmittance = 1.0;
		
		for (float i = 0.0f; i <= CLOUD_RESOLUTION; i+=1.0f)
		{
			vec3 sample_position = entry_point + ray_dir * number_of_steps * i;
			float density = sample_density(sample_position);
			
			if (density > 0.0f)
			{
				float light_transmittance = sample_light_density(sample_position);	
				
				light_energy += density * number_of_steps * transmittance * light_transmittance * PHASE_VALUE;
				transmittance *= exp(-density * number_of_steps * LIGHT_VIEWER_ABSORPTION);
			}
			
		}
		
		vec3 background_color = texture(SCREEN_TEXTURE, SCREEN_UV).rgb;
		
		vec3 cloud_col = MAIN_LIGHT_COLOR.rgb * light_energy;
		vec3 col = background_color * transmittance + cloud_col;
		
		ALBEDO = col;
	}

}
