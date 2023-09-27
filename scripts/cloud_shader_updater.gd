@tool
extends MeshInstance3D


#small helper class which updates stats from the editor and pass it through to the attached shader

class_name CloudShader

@export var light_source : Light3D = null;
@export var scale_factor : float = 1.0

var cloud_texture : Texture3D = null
var detailed_cloud_texture : Texture3D = null


func _physics_process(_dt):
	
	if Engine.is_editor_hint() == false:
		return 
	
	var material : ShaderMaterial = self.get_surface_override_material(0)
	
	if material == null:
		printerr("Warning no material was found")
		return 

	var bbox_min : Vector3 = self.mesh.get_aabb().position * self.scale_factor * self.scale
	var bbox_max : Vector3 = self.mesh.get_aabb().end * self.scale_factor * self.scale
	
	bbox_min += self.global_position
	bbox_max += self.global_position	
	
	
	material.set_shader_parameter("BBOX_MIN", bbox_min)
	material.set_shader_parameter("BBOX_MAX", bbox_max)
	
	if self.light_source != null:
		
		material.set_shader_parameter("MAIN_LIGHT_COLOR", self.light_source.light_color);
		material.set_shader_parameter("MAIN_LIGHT_POSITION", self.light_source.global_position);
		material.set_shader_parameter("MAIN_LIGHT_ENERGY", self.light_source.light_energy)
		material.set_shader_parameter("MAIN_LIGHT_INDIRECT_ENERGY", self.light_source.light_indirect_energy)


func update_cloud_texture(texture : Texture3D) -> void:
	self.cloud_texture = texture
	
	var material : ShaderMaterial = self.get_surface_override_material(0)
	
	if material != null:
		material.set_shader_parameter("DENSITY_MAP",self.cloud_texture)
	
	
func update_detailed_cloud_texture(texture : Texture3D) -> void:
	self.detailed_cloud_texture = texture
	
	
	var material : ShaderMaterial = self.get_surface_override_material(0)
	
	if material != null:
		material.set_shader_parameter("DETAILED_DENSITY_MAP",self.detailed_cloud_texture)
