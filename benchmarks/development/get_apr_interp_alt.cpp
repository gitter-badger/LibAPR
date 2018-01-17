
#include <algorithm>
#include <iostream>

#include "test/Examples/Example_get_apr.h"
#include "src/data_structures/Mesh/MeshData.hpp"
#include "benchmarks/development/old_io/readimage.h"

#include "benchmarks/development/old_algorithm/gradient.hpp"
#include "benchmarks/development/old_structures/particle_map.hpp"
#include "benchmarks/development/Tree/PartCellStructure.hpp"
#include "benchmarks/development/old_algorithm/level.hpp"
#include "benchmarks/development/old_io/writeimage.h"
#include "benchmarks/development/old_io/write_parts.h"
#include "benchmarks/development/old_io/partcell_io.h"
#include "test/utils.h"

bool command_option_exists(char **begin, char **end, const std::string &option)
{
    return std::find(begin, end, option) != end;
}

char* get_command_option(char **begin, char **end, const std::string &option)
{
    char ** itr = std::find(begin, end, option);
    if (itr != end && ++itr != end)
    {
        return *itr;
    }
    return 0;
}

cmdLineOptions read_command_line_options(int argc, char **argv, Part_rep& part_rep){
    
    cmdLineOptions result;
    
    if(argc == 1) {
        std::cerr << "Usage: \"pipeline -i inputfile [-t] [-s statsfile -d directory] [-o outputfile]\"" << std::endl;
        exit(1);
    }
    
    if(command_option_exists(argv, argv + argc, "-i"))
    {
        result.input = std::string(get_command_option(argv, argv + argc, "-i"));
    } else {
        std::cout << "Input file required" << std::endl;
        exit(2);
    }
    
    if(command_option_exists(argv, argv + argc, "-o"))
    {
        result.output = std::string(get_command_option(argv, argv + argc, "-o"));
    }
    
    if(command_option_exists(argv, argv + argc, "-d"))
    {
        result.directory = std::string(get_command_option(argv, argv + argc, "-d"));
    }
    if(command_option_exists(argv, argv + argc, "-s"))
    {
        result.stats = std::string(get_command_option(argv, argv + argc, "-s"));
        get_image_stats(part_rep.pars, result.directory, result.stats);
        result.stats_file = true;
    }
    if(command_option_exists(argv, argv + argc, "-t"))
    {
        part_rep.timer.verbose_flag = true;
    }
    
    return result;
    
}



int main(int argc, char **argv) {
    
    Part_rep part_rep;
    
    // INPUT PARSING
    
    cmdLineOptions options = read_command_line_options(argc, argv, part_rep);
    
    // COMPUTATIONS
    
    MeshData<float> input_image_float;
    MeshData<float> gradient, variance;
    
    MeshData<float> interp_img;
    
    {
        MeshData<uint16_t> input_image;
        
        load_image_tiff(input_image, options.directory + options.input);
        
        gradient.initialize(input_image.y_num, input_image.x_num, input_image.z_num, 0);
        part_rep.initialize(input_image.y_num, input_image.x_num, input_image.z_num);
        
        input_image_float = input_image.to_type<float>();
        interp_img = input_image.to_type<float>();
        // After this block, input_image will be freed.
    }
    
    if(!options.stats_file) {
        // defaults
        
        part_rep.pars.dy = part_rep.pars.dx = part_rep.pars.dz = 1;
        part_rep.pars.psfx = part_rep.pars.psfy = part_rep.pars.psfz = 1;
        part_rep.pars.rel_error = 0.1;
        part_rep.pars.var_th = 0;
        part_rep.pars.var_th_max = 0;
    }
    
    Part_timer t;
    t.verbose_flag = true;
    
    // preallocate_memory
    Particle_map<float> part_map(part_rep);
    preallocate(part_map.layers, gradient.y_num, gradient.x_num, gradient.z_num, part_rep);
    variance.preallocate(gradient.y_num, gradient.x_num, gradient.z_num, 0);
    std::vector<MeshData<float>> down_sampled_images;
    
    MeshData<float> temp;
    temp.preallocate(gradient.y_num, gradient.x_num, gradient.z_num, 0);
    
    t.start_timer("whole");
    
    part_map.downsample(interp_img);
    
    part_rep.timer.start_timer("get_gradient_3D");
    get_gradient_3D(part_rep, input_image_float, gradient);
    part_rep.timer.stop_timer();
    
    
    part_rep.timer.start_timer("get_variance_3D");
    get_variance_3D(part_rep, input_image_float, variance);
    part_rep.timer.stop_timer();
    
    
    
    part_rep.timer.start_timer("get_level_3D");
    get_level_3D(variance, gradient, part_rep, part_map, temp);
    part_rep.timer.stop_timer();
    
    
    // free memory (not used anymore)
    std::vector<float>().swap( gradient.mesh );
    std::vector<float>().swap( variance.mesh );
    
    part_rep.timer.start_timer("pushing_scheme");
    part_map.pushing_scheme(part_rep);
    part_rep.timer.stop_timer();
    
    
    part_rep.timer.start_timer("Construct Part Structure");
    
    PartCellStructure<float,uint64_t> pcell_test(part_map);
    
    part_rep.timer.stop_timer();
    
    //output
    std::string save_loc = options.directory;
    std::string file_name = options.output;
    
    part_rep.timer.start_timer("writing output");
    
    write_apr_pc_struct(pcell_test,save_loc,file_name);
    
    part_rep.timer.stop_timer();
    
    
    MeshData<uint64_t> interp;
    
    
    pcell_test.interp_parts_to_pc(interp,pcell_test.part_data.particle_data);
    
    debug_write(interp,"interp_out_alt");
    
}


