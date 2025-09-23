# SPDX-FileCopyrightText: 2023 Efabless Corporation

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#      http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# SPDX-License-Identifier: Apache-2.0
import click
import yaml


@click.command()
@click.argument('user_project_root', type=click.Path(exists=True))
def update_design_info(user_project_root):
    data = {
        'CARAVEL_ROOT': "/nc/templates/caravel",
        'MCW_ROOT': "/nc/templates/mgmt_core_wrapper",
        'USER_PROJECT_ROOT': user_project_root,
        'PDK_ROOT': "/nc/apps/pdk",
        'PDK': "sky130A",
        'clk_period_ns': 25,
        'caravan': False,
        'emailto': [None]
    }

    with open(f'{user_project_root}/verilog/dv/cocotb/design_info.yaml', 'w') as file:
        yaml.dump(data, file)

    with open(f'{user_project_root}/verilog/dv/cocotb/design_info.yaml', 'w') as file:
        yaml_str = yaml.dump(data)
        yaml_str = yaml_str.replace("clk_period_ns: 25",
                                    "clk_period_ns: 25   # Clock period in nanoseconds")
        file.write(yaml_str)

if __name__ == "__main__":
    update_design_info()
