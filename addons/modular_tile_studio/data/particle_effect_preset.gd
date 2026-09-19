@tool
class_name ParticleEffectPreset
extends Resource

## Defines one reusable PNG-driven GPUParticles3D effect without hiding simulation values.
##
## A preset owns appearance and motion only. Board-space position belongs to
## ParticleEffectPlacement so the same effect can be laid down in many places.

@export var preset_id: String = ""
@export var display_name: String = "Particle Effect"
@export var texture_path: String = ""

@export_range(1, 100000, 1) var amount: int = 100
@export_range(0.01, 120.0, 0.01) var lifetime_seconds: float = 4.0
@export_range(0.0, 1.0, 0.01) var explosiveness: float = 0.0
@export_range(0.0, 1.0, 0.01) var emission_randomness: float = 0.0
@export var one_shot: bool = false
@export var fixed_seed: int = 1

## Full authored emitter box size in metres; the renderer derives Godot's half-extents.
@export var emission_box_size_m: Vector3 = Vector3(2.0, 2.0, 2.0)
@export var direction: Vector3 = Vector3.UP
@export_range(0.0, 180.0, 0.1) var spread_degrees: float = 45.0
@export_range(0.0, 256.0, 0.01) var initial_velocity_min: float = 0.05
@export_range(0.0, 256.0, 0.01) var initial_velocity_max: float = 0.25
@export var gravity: Vector3 = Vector3(0.0, 0.02, 0.0)
@export_range(-720.0, 720.0, 0.1) var angular_velocity_min: float = -20.0
@export_range(-720.0, 720.0, 0.1) var angular_velocity_max: float = 20.0

## Quad size is measured directly in metres because the authored draw mesh is one metre square.
@export_range(0.001, 64.0, 0.001) var particle_size_min_m: float = 0.02
@export_range(0.001, 64.0, 0.001) var particle_size_max_m: float = 0.08
@export var tint: Color = Color.WHITE
@export_range(0.01, 0.49, 0.01) var fade_in_fraction: float = 0.10
@export_range(0.01, 0.49, 0.01) var fade_out_fraction: float = 0.20
@export_range(0.0, 32.0, 0.01) var emission_energy: float = 0.0


## Return whether this preset has every required value needed to construct an emitter.
func is_valid() -> bool:
	return (
		not preset_id.is_empty()
		and not display_name.is_empty()
		and not texture_path.is_empty()
		and amount > 0
		and lifetime_seconds > 0.0
		and emission_box_size_m.x > 0.0
		and emission_box_size_m.y > 0.0
		and emission_box_size_m.z > 0.0
		and particle_size_min_m > 0.0
		and particle_size_max_m >= particle_size_min_m
		and initial_velocity_max >= initial_velocity_min
	)
