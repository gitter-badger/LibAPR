//
// Created by cheesema on 21.01.18.
//

#ifndef PARTPLAY_EXAMPLE_PRODUCE_PARAVIEW_FILE_HPP
#define PARTPLAY_EXAMPLE_PRODUCE_PARAVIEW_FILE_HPP

#include <functional>
#include <string>

#include "data_structures/APR/APR.hpp"

struct cmdLineOptions{
    std::string output = "output";
    std::string stats = "";
    std::string directory = "";
    std::string input = "";
    bool stats_file = false;
};

cmdLineOptions read_command_line_options(int argc, char **argv);

bool command_option_exists(char **begin, char **end, const std::string &option);

char* get_command_option(char **begin, char **end, const std::string &option);


#endif //PARTPLAY_EXAMPLE_PRODUCE_PARAVIEW_FILE_HPP
