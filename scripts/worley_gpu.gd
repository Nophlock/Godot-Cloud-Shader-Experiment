@tool
extends Node


@export_category("Debug")
@export var init_compute_shader : bool = false:
	set(_new_value):
		init_gpu()

@export_category("Setup")	
@export_file("*.glsl") var shader_file
@export var node_to_apply : CloudShader = null 
@export var is_detailed_map : bool = false


@export_category("Parameter")	

@export var resolution : Vector3i = Vector3i(64,64,64):
	set(new_value):
		resolution = new_value
		self.regen_texture()

@export var channel_r : Vector3i = Vector3(2,4,8):
	set(new_value):
		channel_r = new_value
		self.regen_texture()


@export var channel_g : Vector3i = Vector3(2,4,8):
	set(new_value):
		channel_g = new_value
		self.regen_texture()

@export var channel_b : Vector3i = Vector3(2,4,8):
	set(new_value):
		channel_b = new_value
		self.regen_texture()

@export var channel_a : Vector3i = Vector3(2,4,8):
	set(new_value):
		channel_a = new_value
		self.regen_texture()

@export_range(0.0, 1.0) var persistence : float = 0.5:
	set(new_value):
		persistence = new_value
		self.regen_texture(false)
		
@export var invert_image : bool = false:
	set(new_value):
		invert_image = new_value
		self.regen_texture(false)
	
@export_category("Result")	
@export var isolate_channel : Vector4i = Vector4i(0,0,0,0):
	set(new_value):
		isolate_channel = new_value
		self.regen_texture(false)

@export var cloud_texture : Texture3D = null



var rd: RenderingDevice
var shader_rid: RID
var texture_rid: RID
var gradient_rid: RID
var uniform_set: RID
var pipeline: RID
var points_buffer : RID

var sample_points : PackedVector3Array = PackedVector3Array()
var parameters : PackedFloat32Array
var parameter_buffer : RID
var offsets : PackedFloat32Array
var offsets_buffer : RID


#load the compute shader
func load_shader(device: RenderingDevice, path: String) -> RID:
	var shader_file_data: RDShaderFile = load(path)
	var shader_spirv: RDShaderSPIRV = shader_file_data.get_spirv()
	return device.shader_create_from_spirv(shader_spirv)



#init the compute shader on the gpu
func init_gpu(soft_clean : bool = false) -> void:
	
	#only create the render device once (ideally)
	if soft_clean == false or rd == null:

		if rd != null:
			self.cleanup_gpu()
			
		rd = RenderingServer.create_local_rendering_device()
		shader_rid = load_shader(rd, shader_file)
	else:
		self.soft_cleanup_gpu()

	# Create texture
	var texture_format := RDTextureFormat.new()

	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	texture_format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	texture_format.width = resolution.x
	texture_format.height = resolution.y
	texture_format.depth = resolution.z
	
	texture_format.usage_bits = (
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
			RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT |
			RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)

	texture_rid = rd.texture_create(texture_format, RDTextureView.new())
	var texture_uniform : RDUniform = RDUniform.new()
	texture_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	texture_uniform.binding = 0  # This matches the binding in the shader.
	texture_uniform.add_id(texture_rid)
	
	
	#Create sample points buffer
	var offset_array : PackedFloat32Array = self.generate_offsets_array()
	var total_size : int = int(offset_array[-1])
	
	sample_points.resize(total_size)
	var sample_points_bytes : PackedByteArray = sample_points.to_byte_array()

	points_buffer = rd.storage_buffer_create(sample_points_bytes.size(), sample_points_bytes)
	var points_uniform := RDUniform.new()
	points_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	points_uniform.binding = 1 
	points_uniform.add_id(points_buffer)
	
	
	#Create parameter buffer
	parameters = PackedFloat32Array(self.generate_parameter_array())
	var paramters_bytes : PackedByteArray = parameters.to_byte_array()

	parameter_buffer = rd.storage_buffer_create(paramters_bytes.size(), paramters_bytes)
	var parameter_uniform := RDUniform.new()
	parameter_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	parameter_uniform.binding = 2 
	parameter_uniform.add_id(parameter_buffer)
	
	
	#Create offset buffer
	offsets = offset_array
	var offset_bytes : PackedByteArray = offsets.to_byte_array()

	offsets_buffer = rd.storage_buffer_create(offset_bytes.size(), offset_bytes)
	var offset_uniform := RDUniform.new()
	offset_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	offset_uniform.binding = 3 
	offset_uniform.add_id(offsets_buffer)


	uniform_set = rd.uniform_set_create([texture_uniform, points_uniform, parameter_uniform, offset_uniform], shader_rid, 0)
	pipeline = rd.compute_pipeline_create(shader_rid)


#cleanup everything of the compute shader
func cleanup_gpu() -> void:
	
	if rd == null:
		return

	self.soft_cleanup_gpu()
	
	if shader_rid.is_valid():
		rd.free_rid(shader_rid)
		shader_rid = RID()

	rd.free()
	rd = null
	

#cleanup all parameters of the compute shader but not the shader and the device manager
func soft_cleanup_gpu() -> void:
	
	if self.rd == null:
		return 
	
	if pipeline.is_valid():
		rd.free_rid(pipeline)
		pipeline = RID()

	if uniform_set.is_valid():
		rd.free_rid(uniform_set)
		uniform_set = RID()

	if texture_rid.is_valid():
		rd.free_rid(texture_rid)
		texture_rid = RID()
		
	if points_buffer.is_valid():
		rd.free_rid(points_buffer)
		points_buffer = RID()
		
	if parameter_buffer.is_valid():
		rd.free_rid(parameter_buffer)
		parameter_buffer = RID()
		
	if offsets_buffer.is_valid():
		rd.free_rid(offsets_buffer)
		offsets_buffer = RID()


#generate our sample points in a grid structure (allows a lot of optimization for the worley algorithm)
func generate_sample_points(divisions : int) -> PackedVector3Array:
	
	var f_div = float(divisions)
	var grid_size : Vector3 = Vector3(float(resolution.x) / f_div, float(resolution.y) / f_div, float(resolution.z) / f_div ) 
	var points : PackedVector3Array = []
	
	for z in range(divisions):
		for y in range(divisions):
			for x in range(divisions):
				
				var x_start : float = x * grid_size.x
				var y_start : float = y * grid_size.y
				var z_start : float = z * grid_size.z
				
				var point_pos : Vector3 = Vector3(	randf_range(x_start, x_start + grid_size.x),
													randf_range(y_start, y_start + grid_size.y),
													randf_range(z_start, z_start + grid_size.z))
													
				points.append(point_pos)

	return points


#generate our offset array which indicate where which sections of sample points will start
func generate_offsets_array() -> PackedFloat32Array:
	var x0 : int = 0
	var x1 : int = x0 + (channel_r.x * channel_r.x * channel_r.x) * 3
	var x2 : int = x1 + (channel_r.y * channel_r.y * channel_r.y) * 3
	var x3 : int = x2 + (channel_r.z * channel_r.z * channel_r.z) * 3
	
	var x4 : int  = x3 + (channel_g.x * channel_g.x * channel_g.x) * 3
	var x5 : int  = x4 + (channel_g.y * channel_g.y * channel_g.y) * 3
	var x6 : int  = x5 + (channel_g.z * channel_g.z * channel_g.z) * 3
	
	var x7 : int  = x6 + (channel_b.x * channel_b.x * channel_b.x) * 3
	var x8 : int  = x7 + (channel_b.y * channel_b.y * channel_b.y) * 3
	var x9 : int  = x8 + (channel_b.z * channel_b.z * channel_b.z) * 3
	
	var x10  : int = x9  + (channel_a.x * channel_a.x * channel_a.x) * 3
	var x11 : int  = x10 + (channel_a.y * channel_a.y * channel_a.y) * 3
	var x12 : int  = x11 + (channel_a.z * channel_a.z * channel_a.z) * 3 #this value will never be used since it marks the end point but usefull for the parameter calculation
	
	return PackedFloat32Array( [x0, x1,x2,x3,x4,x5,x6,x7,x8,x9,x10,x11, x12])
	

func generate_parameter_array() -> PackedFloat32Array:
	
	return PackedFloat32Array([persistence, float(invert_image), 
									isolate_channel.x,isolate_channel.y,isolate_channel.z,isolate_channel.w,
									resolution.x, resolution.y, resolution.z,
									channel_r.x, channel_r.y, channel_r.z,
									channel_g.x, channel_g.y, channel_g.z,
									channel_b.x, channel_b.y, channel_b.z,
									channel_a.x, channel_a.y, channel_a.z])
		
	
	
#generate all the sample points in a grid	
func generate_sample_point_array() -> PackedVector3Array:
	
	var iteration_array : Array = [	channel_r.x, channel_r.y, channel_r.z,
									channel_g.x, channel_g.y, channel_g.z,
									channel_b.x, channel_b.y, channel_b.z,
									channel_a.x, channel_a.y, channel_a.z]


	sample_points.resize(0)
		

	for i in range(iteration_array.size()):
		sample_points.append_array(self.generate_sample_points(iteration_array[i] ))

	
	return sample_points

#generate the actual texture by running the prepared compute shader
func generate_cloud_texture(regen_points : bool = true) -> void:
	
	if shader_file == null:
		return 
	
	if rd == null:
		print("Regen GPU compute shader")
		self.init_gpu()
	
	
	if regen_points:
		sample_points = self.generate_sample_point_array()
		
	var sample_points_bytes : PackedByteArray = sample_points.to_byte_array()
	rd.buffer_update(points_buffer, 0, sample_points_bytes.size(), sample_points_bytes)
	
	parameters = self.generate_parameter_array()
	var parameters_bytes : PackedByteArray = parameters.to_byte_array()
	
	offsets = self.generate_offsets_array()
	var offsets_bytes : PackedByteArray = offsets.to_byte_array()
	
	rd.buffer_update(parameter_buffer, 0, parameters_bytes.size(), parameters_bytes)
	rd.buffer_update(offsets_buffer, 0, offsets_bytes.size(), offsets_bytes)

	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)

	@warning_ignore("integer_division")
	rd.compute_list_dispatch(compute_list, resolution.x / 8, resolution.y / 8 , resolution.z / 8)
	rd.compute_list_end()

	rd.submit()
	rd.sync()


	var result_texture : Texture3D = ImageTexture3D.new()
	var image_stack : Array[Image] = []
	

	var output_bytes : PackedByteArray = rd.texture_get_data(texture_rid, 0)
	var slice_number : int = resolution.x * resolution.y * 4 #4 = RGBA  *8 Bit


	# Retrieve processed data.
	for depth in range(resolution.z):
		
		var layer_data : PackedByteArray = output_bytes.slice((depth) * slice_number, (depth + 1) * slice_number)
		var slice_img : Image = Image.create_from_data(resolution.x, resolution.y, false, Image.FORMAT_RGBA8, layer_data)
		
		image_stack.append(slice_img)


	result_texture.create(Image.FORMAT_RGBA8, resolution.x, resolution.y, resolution.z, false, image_stack)
	self.cloud_texture = result_texture
	self.cloud_texture.resource_local_to_scene = true


#regenerate the texture and also the samples points if desired
func regen_texture(regen_points : bool = true) -> void:
	self.init_gpu(true)
	self.generate_cloud_texture(regen_points)
	
	if self.node_to_apply != null:
		
		if self.is_detailed_map:
			self.cloud_texture.resource_name = "detailed_clouds"
			self.node_to_apply.update_detailed_cloud_texture(self.cloud_texture)
		else:
			self.cloud_texture.resource_name = "clouds"
			self.node_to_apply.update_cloud_texture(self.cloud_texture)
	
	
#scene notification that this node gets deleted and therefore we need to cleanup the compute shader to prevent leaking
func _notification(what):
	# Object destructor, triggered before the engine deletes this Node.
	if what == NOTIFICATION_PREDELETE:
		cleanup_gpu()

