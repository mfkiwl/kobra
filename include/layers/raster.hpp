#ifndef KOBRA_LAYERS_RASTER_H_
#define KOBRA_LAYERS_RASTER_H_

// Standard headers
#include <map>

// Engine headers
// TODO: move layer.hpp to this directory
// #include "../layer.hpp"

#include "../../shaders/raster/bindings.h"
#include "../../shaders/raster/constants.h"
#include "../backend.hpp"
#include "../ecs.hpp"
#include "../timer.hpp"
#include "../vertex.hpp"

namespace kobra {

namespace layers {

class Raster {
private:
	// Vulkan context
	Context				_ctx;

	// Other Vulkan structures
	vk::raii::RenderPass		_render_pass = nullptr;

	vk::raii::PipelineLayout	_ppl = nullptr;
	vk::raii::Pipeline		_p_albedo = nullptr;
	vk::raii::Pipeline		_p_normal = nullptr;
	vk::raii::Pipeline		_p_phong = nullptr;

	// Buffer for all the lights
	struct LightsData;

	BufferData			_b_lights = nullptr;

	// Skybox data
	struct Skybox {
		bool enabled = false;
		bool initialized = false;

		BufferData vertex_buffer = nullptr;
		BufferData index_buffer = nullptr;

		std::string path;

		vk::raii::Pipeline pipeline = nullptr;
		vk::raii::PipelineLayout ppl = nullptr;
		vk::raii::DescriptorSetLayout dsl = nullptr;
		vk::raii::DescriptorSet dset = nullptr;

		static const std::vector <DSLB>	dsl_bindings;

		// TODO: equiangular or 6 faces?
	} _skybox;

	// Initialize the skybox
	void _initialize_skybox();

	// Bind pipeline from raster mode
	const vk::raii::Pipeline &get_pipeline(RasterMode);

	// Descriptor set layout and bindings
	vk::raii::DescriptorSetLayout	_dsl = nullptr;

	static const std::vector <DSLB>	_dsl_bindings;

	// Create a descriptor set
	vk::raii::DescriptorSet	_make_ds() const;

	// Renderable components to descriptor set
	std::set <const Renderable *>	_cached_rasterizers;

	// Box mesh for area lights
	Renderable			*_area_light;

	// Timer
	Timer				_timer;
public:
	// Default constructor
	Raster() = default;

	// Constructors
	Raster(const Context &, const vk::AttachmentLoadOp &);

	// Methods
	void environment_map(const std::string &);

	// Render
	void render(const vk::raii::CommandBuffer &,
			const vk::raii::Framebuffer &,
			const ECS &,
			const RenderArea & = RenderArea {{-1, -1}, {-1, -1}});
};

}

}

#endif
