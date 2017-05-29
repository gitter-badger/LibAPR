//
// Created by cheesema on 26.05.17.
//

//
// Created by cheesema on 31/01/17.
//

#include "Generate_APR_Time.hpp"


int main(int argc, char **argv) {

    //////////////////////////////////////////
    //
    //
    //  First set up the synthetic problem to be solved
    //
    //
    ///////////////////////////////////////////

    std::cout << "Generate Single Syn Image" << std::endl;

    cmdLineOptionsBench options = read_command_line_options(argc, argv);

    SynImage syn_image;

    std::string image_name = options.template_name;

    benchmark_settings bs;

    set_up_benchmark_defaults(syn_image, bs);

    /////////////////////////////////////////////
    // GENERATE THE OBJECT TEMPLATE

    std::cout << "Generating Templates" << std::endl;

    /////////////////////////////////////////////////////////////////
    //
    //
    //  Now perform the experiment looping over and generating datasets x times.
    //
    //
    //
    //////////////////////////////////////////////////////////////////

    AnalysisData analysis_data(options.description, "Gen Single Image", argc, argv);

    process_input(options, syn_image, analysis_data, bs);




    bs.obj_size = 1.5;
    bs.sig = 2.0;
    //bs.desired_I = 10000;
    float ratio = 5;
    bs.num_objects = round(pow(bs.x_num,3)/(33400*ratio));

    //bs.num_objects = 40;

    bs.desired_I = 500;
    //bs.int_scale_max = 1;
    //bs.int_scale_min = 1;
    bs.int_scale_min = 1;
    bs.int_scale_max = 10;

    obj_properties obj_prop(bs);

    Object_template basic_object = get_object_template(options, obj_prop);

    syn_image.object_templates.push_back(basic_object);

    TimeModel cell_model((int)bs.num_objects);


    //time parameters
    float T_num = options.delta ;
    float Et = 0.1;
    std::vector<float> t_dim = {0,1};

    generate_objects(syn_image, bs);

    float prop_move = bs.rel_error;

    bs.rel_error = 0.1;



    for (int i = 0; i < syn_image.real_objects.size(); ++i) {
        cell_model.location[i][0] = syn_image.real_objects[i].location[0];
        cell_model.location[i][1] = syn_image.real_objects[i].location[1];
        cell_model.location[i][2] = syn_image.real_objects[i].location[2];

        if((i/bs.num_objects) < prop_move) {

            cell_model.move_speed[i] = cell_model.gen_rand.rand_num(0, 0.05);

        } else {
            cell_model.move_speed[i] = 0;
        }

        cell_model.theta[i] = cell_model.gen_rand.rand_num(0,M_PI);
        cell_model.phi[i] = cell_model.gen_rand.rand_num(0,2*M_PI);

        cell_model.direction_speed[i] = cell_model.gen_rand.rand_num(0,0.1);
    }





    APR_Time apr_t;

    set_gaussian_psf(syn_image, bs);

    Part_timer timer;

    float total_p = 0;
    float total_used = 0;


    for (int t = 0; t < T_num; ++t) {


        SynImage syn_image_loc = syn_image;

        //add the basic sphere as the standard template

        ///////////////////////////////////////////////////////////////////
        //PSF properties

        move_objects(syn_image_loc,bs,cell_model);
        //bs.sig = 5;


        // Get the APR
        //bs.num_objects = 10;


        ///////////////////////////////
        //
        //  Generate the image
        //
        ////////////////////////////////



        MeshDataAF<uint16_t> gen_image;

        syn_image_loc.generate_syn_image(gen_image);

        Mesh_data<uint16_t> input_img;

        copy_mesh_data_structures(gen_image, input_img);


        ///////////////////////////////
        //
        //  Get the APR
        //
        //////////////////////////////


        Part_rep p_rep;

        set_up_part_rep(syn_image_loc, p_rep, bs);


        p_rep.timer.verbose_flag = true;

        p_rep.pars.pull_scheme = 2;


        PartCellStructure<float, uint64_t> pc_struct;


        bench_get_apr(input_img, p_rep, pc_struct, analysis_data);


        APR<float> apr_c(pc_struct);

        ExtraPartCellData<float> curr_scale =  get_scale_parts(apr_c,input_img,p_rep.pars);
        timer.verbose_flag = true;

        timer.start_timer("time_loop");

        if(t == 0){

            apr_t.initialize(apr_c,t_dim,Et,T_num,curr_scale);



        } else {

            APR<float> apr_temp = apr_c;

            apr_t.integrate_new_t(apr_c,curr_scale,t);

            float add = apr_t.add[t].structure_size();
            float remove =apr_t.remove[t].structure_size();
            float same = apr_t.same_index.structure_size();
            float total_parts = pc_struct.get_number_parts();


            float update = apr_t.update_fp[t].structure_size();

            float total_2 = add + remove + update;

            std::cout << "add: " << add << std::endl;
            std::cout << "remove: " << remove << std::endl;
            std::cout << "same: " << same << std::endl;
            std::cout << "update: " << update << std::endl;
            std::cout << "parts: " << total_parts << std::endl;
            std::cout << "used: " << total_2 << std::endl;

            total_p += total_parts;
            total_used += total_2;

            analysis_data.add_float_data("add",add);
            analysis_data.add_float_data("remove",remove);
            analysis_data.add_float_data("update",update);
            analysis_data.add_float_data("same",same);
            analysis_data.add_float_data("total_used",total_used);


           Mesh_data<float> test_recon;

            interp_img(test_recon,apr_temp.y_vec,apr_t.parts_recon_prev);

            //debug_write(test_recon,"recon_"+ std::to_string((int)t));

            std::string name = "recgt";

            //get the MSE
            calc_mse(input_img, test_recon, name, analysis_data);
            compare_E(input_img, test_recon,p_rep.pars, name, analysis_data);


//            Mesh_data<float> tp;
//
//            interp_img(tp,apr_temp.y_vec,apr_t.prev_tp);
//
//            debug_write(tp,"tp_"+ std::to_string((int)t));
//
//
//            Mesh_data<float> sp;
//
//            interp_img(sp,apr_temp.y_vec,apr_t.prev_sp);
//
//            debug_write(test_recon,"sp_"+ std::to_string((int)t));
//
//
//            Mesh_data<float> lp;
//
//            interp_img(lp,apr_temp.y_vec,apr_t.prev_l);
//
//            debug_write(test_recon,"lp_"+ std::to_string((int)t));


        }

        timer.stop_timer();




        //write_image_tiff(input_img, p_rep.pars.output_path + p_rep.pars.name + "_time_seq_" + std::to_string(t) + ".tif");



        std::cout << pc_struct.get_number_parts() << std::endl;

        ///////////////////////////////
        //
        //  Calculate analysis of the result
        //
        ///////////////////////////////

        produce_apr_analysis(input_img, analysis_data, pc_struct, syn_image_loc, p_rep.pars);


    }

    std::cout << "used total: " << total_used << std::endl;
    std::cout << "prats total: " << total_p << std::endl;
    std::cout << "ratio: " << total_p/total_used << std::endl;
    std::cout << "total ratio: " << (pow(bs.x_num,3)*T_num)/total_used << std::endl;

    //write the analysis output
    analysis_data.write_analysis_data_hdf5();

    af::info();





    return 0;
}
