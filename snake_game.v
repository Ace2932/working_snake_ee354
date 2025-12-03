`timescale 1ns / 1ps

module snake_game (
    input              clk,          // 100 MHz system clock
    input              bright,       // asserted for visible pixels
    input              rst,          // synchronous active-high reset
    input              button,       // center button for restart
    input      [14:0]  acl_data,     // accelerometer sample (X,Y,Z packed)
    input      [9:0]   hCount,       // horizontal pixel counter
    input      [9:0]   vCount,       // vertical pixel counter
    output reg [11:0]  rgb,          // 12-bit packed RGB (4:4:4)
    output reg [15:0]  score         // score for 7-seg display
);

    localparam integer GRID_WIDTH        = 16;
    localparam integer GRID_HEIGHT       = 16;
    localparam integer CELL_WIDTH        = 40;
    localparam integer CELL_HEIGHT       = 30;
    localparam integer STEP_INTERVAL     = 50_000_000; // 0.5 second @ 100 MHz
    localparam integer MAX_SNAKE_CELLS   = GRID_WIDTH * GRID_HEIGHT;
    localparam [15:0] SCORE_MAX          = 16'h9999;

    localparam [11:0] COLOR_BACKGROUND   = 12'h118;
    localparam [11:0] COLOR_GRID         = 12'h333;
    localparam [11:0] COLOR_SNAKE_HEAD   = 12'h0F0;
    localparam [11:0] COLOR_SNAKE_BODY   = 12'h0C8;
    localparam [11:0] COLOR_FRUIT        = 12'hF00;
    localparam [11:0] COLOR_GAME_OVER    = 12'hF44;

    localparam [1:0] DIR_UP    = 2'd0;
    localparam [1:0] DIR_RIGHT = 2'd1;
    localparam [1:0] DIR_DOWN  = 2'd2;
    localparam [1:0] DIR_LEFT  = 2'd3;

    // Synchronise and edge-detect the restart button
    reg btn_meta, btn_sync, btn_prev;
    always @(posedge clk) begin
        btn_meta <= button;
        btn_sync <= btn_meta;
        btn_prev <= btn_sync;
    end
    wire button_pulse = btn_sync & ~btn_prev;

    // Direction decoding helpers
    wire signed [5:0] tilt_vertical   = {acl_data[14], acl_data[14:10]}; // X-axis
    wire signed [5:0] tilt_horizontal = {acl_data[9],  acl_data[9:5]};   // Y-axis

    wire [5:0] abs_vertical   = tilt_vertical[5]   ? (~tilt_vertical   + 6'd1) : tilt_vertical;
    wire [5:0] abs_horizontal = tilt_horizontal[5] ? (~tilt_horizontal + 6'd1) : tilt_horizontal;

    localparam [5:0] DEADZONE = 6'd2; // ignore minor tilt

    wire horizontal_valid = (abs_horizontal >= DEADZONE);
    wire vertical_valid   = (abs_vertical   >= DEADZONE);

    wire choose_horizontal = horizontal_valid && (abs_horizontal >= abs_vertical || !vertical_valid);
    wire choose_vertical   = vertical_valid   && (!horizontal_valid || abs_vertical > abs_horizontal);

    wire [1:0] dir_horizontal = tilt_horizontal[5] ? DIR_RIGHT : DIR_LEFT; // sign bit mirrors Dodo Jump mapping
    wire [1:0] dir_vertical   = tilt_vertical[5]   ? DIR_UP    : DIR_DOWN;

    wire candidate_valid = choose_horizontal || choose_vertical;
    wire [1:0] candidate_dir = choose_horizontal ? dir_horizontal :
                               choose_vertical   ? dir_vertical   :
                               DIR_RIGHT;

    function automatic reg is_opposite;
        input [1:0] a;
        input [1:0] b;
        begin
            case ({a,b})
                {DIR_UP,    DIR_DOWN},
                {DIR_DOWN,  DIR_UP},
                {DIR_LEFT,  DIR_RIGHT},
                {DIR_RIGHT, DIR_LEFT}: is_opposite = 1'b1;
                default:                is_opposite = 1'b0;
            endcase
        end
    endfunction

    function automatic [7:0] lfsr_advance;
        input [7:0] current;
        begin
            lfsr_advance = {current[6:0], current[7] ^ current[5] ^ current[4] ^ current[3]};
            if (lfsr_advance == 8'b0)
                lfsr_advance = 8'h1D; // avoid lock-up at zero
        end
    endfunction

    function automatic [15:0] bcd_increment;
        input [15:0] value;
        reg [15:0] tmp;
        begin
            tmp = value;
            if (value != 16'h9999) begin
                if (tmp[3:0] == 4'h9) begin
                    tmp[3:0] = 4'h0;
                    if (tmp[7:4] == 4'h9) begin
                        tmp[7:4] = 4'h0;
                        if (tmp[11:8] == 4'h9) begin
                            tmp[11:8] = 4'h0;
                            tmp[15:12] = tmp[15:12] + 4'h1;
                        end else begin
                            tmp[11:8] = tmp[11:8] + 4'h1;
                        end
                    end else begin
                        tmp[7:4] = tmp[7:4] + 4'h1;
                    end
                end else begin
                    tmp[3:0] = tmp[3:0] + 4'h1;
                end
            end
            bcd_increment = tmp;
        end
    endfunction

    reg [1:0] dir_request, dir_current;
    always @(posedge clk) begin
        if (rst) begin
            dir_request <= DIR_RIGHT;
        end else if (button_pulse) begin
            dir_request <= DIR_RIGHT;
        end else if (candidate_valid && !is_opposite(candidate_dir, dir_current)) begin
            dir_request <= candidate_dir;
        end
    end

    // Step timer (1 Hz) – halted while game_over asserted
    reg [26:0] step_counter;
    reg        step_tick;
    always @(posedge clk) begin
        if (rst || button_pulse) begin
            step_counter <= 27'd0;
            step_tick    <= 1'b0;
        end else if (step_counter == STEP_INTERVAL - 1) begin
            step_counter <= 27'd0;
            step_tick    <= 1'b1;
        end else begin
            step_counter <= step_counter + 27'd1;
            step_tick    <= 1'b0;
        end
    end

    // Snake state
    reg [4:0] snake_x [0:MAX_SNAKE_CELLS-1];
    reg [4:0] snake_y [0:MAX_SNAKE_CELLS-1];
    reg [8:0] snake_length;
    reg       game_over;

    reg [3:0] fruit_x, fruit_y;
    reg       fruit_pending;

    reg [7:0] lfsr_state;

    wire [3:0] fruit_candidate_x = lfsr_state[3:0];
    wire [3:0] fruit_candidate_y = lfsr_state[7:4];

    reg [4:0] next_head_x;
    reg [4:0] next_head_y;
    reg       border_collision;
    reg       self_collision;
    reg       fruit_collision;
    reg       will_grow;

    integer i;

    always @(*) begin
        next_head_x      = snake_x[0];
        next_head_y      = snake_y[0];
        border_collision = 1'b0;

        case (dir_request)
            DIR_UP: begin
                if (snake_y[0] == 0) border_collision = 1'b1;
                else                  next_head_y      = snake_y[0] - 1'b1;
            end
            DIR_DOWN: begin
                if (snake_y[0] == GRID_HEIGHT - 1) border_collision = 1'b1;
                else                                 next_head_y      = snake_y[0] + 1'b1;
            end
            DIR_LEFT: begin
                if (snake_x[0] == 0) border_collision = 1'b1;
                else                  next_head_x      = snake_x[0] - 1'b1;
            end
            default: begin // DIR_RIGHT
                if (snake_x[0] == GRID_WIDTH - 1) border_collision = 1'b1;
                else                               next_head_x      = snake_x[0] + 1'b1;
            end
        endcase

        will_grow = (!fruit_pending) &&
                    (next_head_x[3:0] == fruit_x) &&
                    (next_head_y[3:0] == fruit_y);

        self_collision = 1'b0;
        for (i = 0; i < MAX_SNAKE_CELLS; i = i + 1) begin
            if (i < snake_length) begin
                if (!will_grow && i == snake_length - 1) begin
                    // tail moves away when not growing
                    self_collision = self_collision;
                end else if (snake_x[i] == next_head_x && snake_y[i] == next_head_y) begin
                    self_collision = 1'b1;
                end
            end
        end

        fruit_collision = 1'b0;
        for (i = 0; i < MAX_SNAKE_CELLS; i = i + 1) begin
            if (i < snake_length) begin
                if (snake_x[i][3:0] == fruit_candidate_x && snake_y[i][3:0] == fruit_candidate_y)
                    fruit_collision = 1'b1;
            end
        end
    end

    task automatic initialise_snake;
        begin
            snake_length <= 9'd4;
            snake_x[0]   <= 5'd8; snake_y[0] <= 5'd8;
            snake_x[1]   <= 5'd7; snake_y[1] <= 5'd8;
            snake_x[2]   <= 5'd6; snake_y[2] <= 5'd8;
            snake_x[3]   <= 5'd5; snake_y[3] <= 5'd8;
            for (i = 4; i < MAX_SNAKE_CELLS; i = i + 1) begin
                snake_x[i] <= 5'd0;
                snake_y[i] <= 5'd0;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            initialise_snake();
            dir_current  <= DIR_RIGHT;
            game_over    <= 1'b0;
            fruit_x      <= 4'd12;
            fruit_y      <= 4'd8;
            fruit_pending <= 1'b0;
            lfsr_state   <= (acl_data[7:0] != 8'b0) ? acl_data[7:0] : 8'hA5;
            score        <= 16'h0000;
        end else if (button_pulse) begin
            initialise_snake();
            dir_current  <= DIR_RIGHT;
            game_over    <= 1'b0;
            fruit_pending <= 1'b1;
            lfsr_state   <= lfsr_advance((acl_data[7:0] != 8'b0) ? acl_data[7:0] : 8'h5A);
            score        <= 16'h0000;
        end else begin
            if (!game_over && step_tick) begin
                if (border_collision || self_collision) begin
                    game_over <= 1'b1;
                end else begin
                    for (i = MAX_SNAKE_CELLS - 1; i > 0; i = i - 1) begin
                        if (i < snake_length) begin
                            snake_x[i] <= snake_x[i-1];
                            snake_y[i] <= snake_y[i-1];
                        end
                    end
                    snake_x[0] <= next_head_x;
                    snake_y[0] <= next_head_y;

                    if (will_grow && snake_length < MAX_SNAKE_CELLS) begin
                        snake_length <= snake_length + 1'b1;
                        fruit_pending <= 1'b1;
                        if (score != SCORE_MAX)
                            score <= bcd_increment(score);
                    end

                    dir_current <= dir_request;
                end
            end

            if (!game_over && fruit_pending) begin
                if (!fruit_collision) begin
                    fruit_x       <= fruit_candidate_x;
                    fruit_y       <= fruit_candidate_y;
                    fruit_pending <= 1'b0;
                end
                lfsr_state <= lfsr_advance(lfsr_state);
            end else if (!game_over && step_tick) begin
                lfsr_state <= lfsr_advance(lfsr_state);
            end
        end
    end

    // Visible area mapping
    localparam integer H_VISIBLE_START = 144;
    localparam integer V_VISIBLE_START = 35;

    reg [9:0] active_x, active_y;
    reg [3:0] cell_x, cell_y;
    reg       within_grid;
    always @(*) begin
        if (bright) begin
            active_x    = hCount - H_VISIBLE_START;
            active_y    = vCount - V_VISIBLE_START;
            within_grid = (active_x < GRID_WIDTH  * CELL_WIDTH) &&
                          (active_y < GRID_HEIGHT * CELL_HEIGHT);
            cell_x      = within_grid ? active_x / CELL_WIDTH  : 4'd0;
            cell_y      = within_grid ? active_y / CELL_HEIGHT : 4'd0;
        end else begin
            active_x    = 10'd0;
            active_y    = 10'd0;
            within_grid = 1'b0;
            cell_x      = 4'd0;
            cell_y      = 4'd0;
        end
    end

    reg is_vertical_grid;
    reg is_horizontal_grid;

    always @(*) begin
        is_vertical_grid   = 1'b0;
        is_horizontal_grid = 1'b0;
        if (within_grid) begin
            if (active_x == GRID_WIDTH * CELL_WIDTH - 1)
                is_vertical_grid = 1'b1;
            else begin
                for (i = 0; i <= GRID_WIDTH; i = i + 1) begin
                    if (active_x == i * CELL_WIDTH)
                        is_vertical_grid = 1'b1;
                end
            end

            if (active_y == GRID_HEIGHT * CELL_HEIGHT - 1)
                is_horizontal_grid = 1'b1;
            else begin
                for (i = 0; i <= GRID_HEIGHT; i = i + 1) begin
                    if (active_y == i * CELL_HEIGHT)
                        is_horizontal_grid = 1'b1;
                end
            end
        end
    end

    reg snake_cell;
    reg snake_head_cell;
    always @(*) begin
        snake_cell      = 1'b0;
        snake_head_cell = 1'b0;
        if (within_grid) begin
            for (i = 0; i < MAX_SNAKE_CELLS; i = i + 1) begin
                if (i < snake_length) begin
                    if (snake_x[i][3:0] == cell_x && snake_y[i][3:0] == cell_y) begin
                        snake_cell      = 1'b1;
                        snake_head_cell = (i == 0);
                    end
                end
            end
        end
    end

    wire fruit_cell = (!fruit_pending) &&
                      within_grid &&
                      (fruit_x == cell_x) &&
                      (fruit_y == cell_y);

    always @(*) begin
        if (!bright) begin
            rgb = 12'h000;
        end else begin
            rgb = COLOR_BACKGROUND;
            if (within_grid) begin
                if (is_vertical_grid || is_horizontal_grid)
                    rgb = COLOR_GRID;
                if (fruit_cell)
                    rgb = COLOR_FRUIT;
                if (snake_cell) begin
                    rgb = snake_head_cell ? COLOR_SNAKE_HEAD : COLOR_SNAKE_BODY;
                    if (game_over)
                        rgb = COLOR_GAME_OVER;
                end
            end
        end
    end

endmodule

