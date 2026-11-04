from setuptools import find_packages, setup

package_name = 'amr_inspection'

setup(
    name=package_name,
    version='0.1.0',
    packages=find_packages(exclude=['test']),
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='amr',
    maintainer_email='dev@example.com',
    description='巡检业务节点：状态机/路线执行/回充',
    license='Apache-2.0',
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [
            'inspection_node = amr_inspection.inspection_node:main',
            'cmd_vel_watchdog = amr_inspection.cmd_vel_watchdog:main',
        ],
    },
)
